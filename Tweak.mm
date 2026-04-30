#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <thread>
#include <chrono>
#include <cstring>

// ============================================================================
// [1. ESTRUCTURAS MATEMÁTICAS]
// ============================================================================

struct FVector {
    float X, Y, Z;
    FVector operator-(const FVector& o) const { return {X-o.X, Y-o.Y, Z-o.Z}; }
    float Dist(const FVector& o) const {
        return sqrtf((X-o.X)*(X-o.X) + (Y-o.Y)*(Y-o.Y) + (Z-o.Z)*(Z-o.Z));
    }
};

struct FRotator { float Pitch, Yaw, Roll; };

static FRotator VecToRot(FVector d) {
    return {
        atan2f(d.Z, sqrtf(d.X*d.X + d.Y*d.Y)) * (180.f / (float)M_PI),
        atan2f(d.Y, d.X)                        * (180.f / (float)M_PI),
        0.f
    };
}

// ============================================================================
// [2. TRUTH TABLE v6.0 — LECTURA PURA (PAC-SAFE)]
// ============================================================================

// Anclas globales (Sección __DATA)
constexpr uintptr_t ADDR_LOCAL_PLAYER    = 0x951788; // _g_LocalPlayer
constexpr uintptr_t ADDR_GOBJECTS         = 0x951778; // GUObjectArray
constexpr uintptr_t ADDR_ROT_BASE_OFF     = 0x951658; // Offset dinámico de rotación
constexpr uintptr_t TOGGLE_SHORTGUN       = 0x9516b2; // bool _SHORTGUNWP

// Offsets Estándar / Ghidra Verified
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x548;  // LocalPlayer -> Controller (User Verified)
constexpr uintptr_t OFF_Pawn              = 0x3d0;  // Controller -> Pawn
constexpr uintptr_t OFF_RootComp          = 0x130;  // AActor -> RootComponent
constexpr uintptr_t OFF_RelativeLoc       = 0x11c;  // SceneComponent -> Location

#define IS_VALID_PTR(p)    ((uintptr_t)(p) > 0x100000000ULL)
#define IS_ALIGNED_PTR(p)  (((uintptr_t)(p) & 0x7) == 0)
#define IS_SAFE_PTR(p)     (IS_VALID_PTR(p) && IS_ALIGNED_PTR(p))

static inline uintptr_t BASE() {
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0));
}
static inline uintptr_t OFF(uintptr_t o) { return BASE() + o; }

// ============================================================================
// [3. ESTADO GLOBAL]
// ============================================================================

static bool g_Active = false;

// ============================================================================
// [4. LÓGICA DE AIMLOCK PASIVA (v6.0)]
// ============================================================================

static void AimlockTick(bool doLog) {
    // Paso 1: Validación de Toggles
    if (!g_Active) return;
    
    bool gameToggle = *reinterpret_cast<bool*>(OFF(TOGGLE_SHORTGUN));
    if (!gameToggle) return;

    // Paso 2: Obtener LocalPlayer (0x951788)
    uintptr_t lpPtr = *reinterpret_cast<uintptr_t*>(OFF(ADDR_LOCAL_PLAYER));
    if (!IS_SAFE_PTR(lpPtr)) return;

    // Paso 3: Obtener Controller y Pawn
    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lpPtr + OFF_PLAYER_CTRL);
    if (!IS_SAFE_PTR(ctrl)) return;

    uintptr_t myPawn = *reinterpret_cast<uintptr_t*>(ctrl + OFF_Pawn);
    if (!IS_SAFE_PTR(myPawn)) return;

    // Paso 4: Iteración de Objetos (GUObjectArray) para buscar enemigo
    uintptr_t objArrayBase = OFF(ADDR_GOBJECTS);
    uintptr_t objects = *reinterpret_cast<uintptr_t*>(objArrayBase + 0x10);
    int numObjects = *reinterpret_cast<int*>(objArrayBase + 0x18);
    
    if (!IS_SAFE_PTR(objects) || numObjects <= 0) return;

    uintptr_t bestEnemy = 0;
    float minDist = 999999.0f;
    
    // Obtenemos mi posición una vez para comparar
    uintptr_t myRoot = *reinterpret_cast<uintptr_t*>(myPawn + OFF_RootComp);
    if (!IS_SAFE_PTR(myRoot)) return;
    FVector myPos = *reinterpret_cast<FVector*>(myRoot + OFF_RelativeLoc);

    // Escaneo optimizado
    int maxScan = (numObjects > 15000) ? 15000 : numObjects;
    for (int i = 0; i < maxScan; i++) {
        uintptr_t item = *reinterpret_cast<uintptr_t*>(objects + (i * 24)); 
        if (!IS_SAFE_PTR(item) || item == myPawn) continue;
        
        uintptr_t root = *reinterpret_cast<uintptr_t*>(item + OFF_RootComp);
        if (!IS_SAFE_PTR(root)) continue;

        FVector enPos = *reinterpret_cast<FVector*>(root + OFF_RelativeLoc);
        float d = myPos.Dist(enPos);
        
        if (d < minDist && d > 1.0f) { // d > 1.0f para no detectarse a sí mismo
            minDist = d;
            bestEnemy = item;
        }
    }

    if (!IS_SAFE_PTR(bestEnemy)) return;

    // Paso 5: Cálculo de Rotación
    uintptr_t enRoot = *reinterpret_cast<uintptr_t*>(bestEnemy + OFF_RootComp);
    if (!IS_SAFE_PTR(enRoot)) return;
    FVector targetPos = *reinterpret_cast<FVector*>(enRoot + OFF_RelativeLoc);
    
    FRotator tgtRot = VecToRot(targetPos - myPos);

    // Paso 6: Escritura de Rotación (Directa — PAC-SAFE)
    // Lee el offset dinámico guardado en 0x951658
    uintptr_t dynamicRotOffset = *reinterpret_cast<uintptr_t*>(OFF(ADDR_ROT_BASE_OFF));
    
    // Si el offset es basura, no escribimos (prevenir crash)
    if (dynamicRotOffset > 0 && dynamicRotOffset < 0x2000) {
        uintptr_t rotAddr = ctrl + dynamicRotOffset;
        if (IS_SAFE_PTR(rotAddr)) {
            *reinterpret_cast<FRotator*>(rotAddr) = tgtRot;
            if (doLog) NSLog(@"[SGLOCK] Aimlock Activo en: 0x%lX", rotAddr);
        }
    }
}

// ============================================================================
// [5. DRIVER DE SINCRONIZACIÓN (CADisplayLink)]
// ============================================================================

@interface SGLockDriver : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation SGLockDriver
static int tickCount = 0;

- (void)start {
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSLog(@"[SGLOCK] v6.0 iniciada. Modo Lectura Pura.");
}

- (void)onFrame:(CADisplayLink*)link {
    bool doLog = (++tickCount >= 60);
    if (doLog) tickCount = 0;
    AimlockTick(doLog);
}
@end

static SGLockDriver* g_Driver = nil;

// ============================================================================
// [6. INTERFAZ GRÁFICA NATIVA]
// ============================================================================

@interface SGLockButton : UIButton
@end

@implementation SGLockButton
- (void)toggle {
    g_Active = !g_Active;
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
}
@end

static void InjectUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { win = w; break; }
        if (!win) return;

        SGLockButton *btn = [SGLockButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(20, 100, 44, 44);
        btn.layer.cornerRadius = 22;
        btn.backgroundColor = UIColor.redColor;
        [btn addTarget:btn action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:btn];

        g_Driver = [[SGLockDriver alloc] init];
        [g_Driver start];
    });
}

// ============================================================================
// [7. INICIALIZACIÓN]
// ============================================================================

__attribute__((constructor))
static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InjectUI();
    });
}