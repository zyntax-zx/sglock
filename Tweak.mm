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
// [2. TRUTH TABLE v4.6 — PURE MEMORY READ (PAC-SAFE)]
// ============================================================================

// Anclas de memoria (Sección __DATA)
constexpr uintptr_t ADDR_GOBJECTS         = 0x951778; // GUObjectArray
constexpr uintptr_t ADDR_LOCAL_PLAYER_PTR = 0x951788; // _g_LocalPlayer
constexpr uintptr_t ADDR_ROT_BASE_OFF     = 0x951658; // Offset dinámico de rotación

// Offsets de Clase (UE4 Standard / Ghidra Verified)
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;   // ULocalPlayer -> APlayerController
constexpr uintptr_t OFF_CTRL_ROTATION     = 0x2e8;  // APlayerController -> ControlRotation
constexpr uintptr_t OFF_Pawn              = 0x3d0;  // APlayerController -> APawn
constexpr uintptr_t OFF_RootComp          = 0x130;  // AActor -> RootComponent
constexpr uintptr_t OFF_RelativeLoc       = 0x11c;  // USceneComponent -> RelativeLocation
constexpr uintptr_t OFF_WeaponID          = 0x618;  // APawn -> WeaponID (Ajustar si es necesario)
constexpr uintptr_t OFF_Health            = 0x67c;  // AActor -> Health

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
// [4. LÓGICA DE ESCANEO PASIVO (Iteración de Objetos)]
// ============================================================================

static void AimlockTick(bool doLog) {
    if (!g_Active) return;

    // ── Paso 1: Obtener LocalPlayer desde __DATA ─────────────────────────────
    uintptr_t lpPtr = *reinterpret_cast<uintptr_t*>(OFF(ADDR_LOCAL_PLAYER_PTR));
    if (!IS_SAFE_PTR(lpPtr)) return;
    if (doLog) NSLog(@"[SGLOCK_DEBUG] LocalPlayer encontrado en DATA: 0x%lX", lpPtr);

    // ── Paso 2: Obtener PlayerController y Pawn ──────────────────────────────
    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lpPtr + OFF_PLAYER_CTRL);
    if (!IS_SAFE_PTR(ctrl)) return;

    uintptr_t myPawn = *reinterpret_cast<uintptr_t*>(ctrl + OFF_Pawn);
    if (!IS_SAFE_PTR(myPawn)) return;

    // ── Paso 3: Filtro de Arma (Lectura Pasiva) ──────────────────────────────
    int wid = *reinterpret_cast<int*>(myPawn + OFF_WeaponID); 
    bool isShotgun = (((wid - 0x19641) < 4) || (wid == 0x196a5));
    if (doLog) NSLog(@"[SGLOCK_DEBUG] WeaponID: 0x%X | isShotgun: %s", wid, isShotgun ? "SI" : "NO");
    if (!isShotgun) return;

    // ── Paso 4: Iterar GUObjectArray para buscar enemigos ────────────────────
    uintptr_t objArrayBase = OFF(ADDR_GOBJECTS);
    uintptr_t objects = *reinterpret_cast<uintptr_t*>(objArrayBase + 0x10);
    int numObjects = *reinterpret_cast<int*>(objArrayBase + 0x18);
    
    if (!IS_SAFE_PTR(objects) || numObjects <= 0) return;

    uintptr_t bestEnemy = 0;
    float minDist = 999999.0f;

    // Escaneo limitado para rendimiento en Jailed
    int maxScan = (numObjects > 10000) ? 10000 : numObjects;
    
    for (int i = 0; i < maxScan; i++) {
        uintptr_t item = *reinterpret_cast<uintptr_t*>(objects + (i * 24)); // FUObjectItem size = 24
        if (!IS_SAFE_PTR(item)) continue;
        
        // Filtro básico de clase (esto es genérico, en UE4 real se usa NameIndex)
        // Por ahora confiamos en la validación de punteros y distancia
        uintptr_t root = *reinterpret_cast<uintptr_t*>(item + OFF_RootComp);
        if (!IS_SAFE_PTR(root) || item == myPawn) continue;

        FVector enLoc = *reinterpret_cast<FVector*>(root + OFF_RelativeLoc);
        FVector myLoc = *reinterpret_cast<FVector*>(*reinterpret_cast<uintptr_t*>(myPawn + OFF_RootComp) + OFF_RelativeLoc);
        
        float d = myLoc.Dist(enLoc);
        if (d < minDist && d > 10.0f) {
            minDist = d;
            bestEnemy = item;
        }
    }

    if (!IS_SAFE_PTR(bestEnemy)) return;

    // ── Paso 5: Cálculo de Rotación ──────────────────────────────────────────
    uintptr_t myRoot = *reinterpret_cast<uintptr_t*>(myPawn + OFF_RootComp);
    uintptr_t enRoot = *reinterpret_cast<uintptr_t*>(bestEnemy + OFF_RootComp);
    
    FVector myPos = *reinterpret_cast<FVector*>(myRoot + OFF_RelativeLoc);
    FVector enPos = *reinterpret_cast<FVector*>(enRoot + OFF_RelativeLoc);
    
    FRotator tgt = VecToRot(enPos - myPos);

    // ── Paso 6: Escritura de Rotación (Directa a Memoria — PAC Safe) ──────────
    // Obtenemos el offset dinámico de rotación guardado en ADDR_ROT_BASE_OFF
    uintptr_t dynamicRotOffset = *reinterpret_cast<uintptr_t*>(OFF(ADDR_ROT_BASE_OFF));
    
    // Si el offset no es válido, usamos el estandar 0x2e8 como fallback
    uintptr_t finalRotAddr = (dynamicRotOffset > 0 && dynamicRotOffset < 0x2000) 
                             ? (ctrl + dynamicRotOffset) 
                             : (ctrl + OFF_CTRL_ROTATION);

    if (IS_SAFE_PTR(finalRotAddr)) {
        *reinterpret_cast<FRotator*>(finalRotAddr) = tgt;
        if (doLog) NSLog(@"[SGLOCK_DEBUG] Aimlock aplicado a: 0x%lX", finalRotAddr);
    }
}

// ============================================================================
// [5. CADISPLAYLINK CONTROLLER]
// ============================================================================

@interface SGLockDriver : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
- (void)start;
- (void)onFrame:(CADisplayLink*)link;
@end

@implementation SGLockDriver
static int tickCount = 0;

- (void)start {
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSLog(@"[SGLOCK_DEBUG] Driver de Lectura Pura iniciado.");
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
    NSLog(@"[SGLOCK_DEBUG] TOGGLE: %s", g_Active ? "ON" : "OFF");
}
- (void)pan:(UIPanGestureRecognizer*)r {
    if (r.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [r translationInView:self.superview];
        self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
        [r setTranslation:CGPointZero inView:self.superview];
    }
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
        btn.alpha = 0.8f;
        [btn addTarget:btn action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(pan:)];
        [btn addGestureRecognizer:pan];
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
        NSLog(@"[SGLOCK_DEBUG] Sistema v4.6 cargado.");
    });
}
