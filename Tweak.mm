#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <thread>
#include <chrono>
#include <cstring>
#include <vector>

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
// [2. TRUTH TABLE v7.0 — ESCANEO PASIVO GUOBJECTARRAY]
// ============================================================================

constexpr uintptr_t ADDR_GOBJECTS         = 0x951778; // GUObjectArray Maestro
constexpr uintptr_t ADDR_ROT_BASE_OFF     = 0x951658; // Offset dinámico Rotación
constexpr uintptr_t TOGGLE_SHORTGUN       = 0x9516b2; // bool _ShortGunWP (Nota: con R)

// Offsets de Estructura Interna (Pure Read)
constexpr uintptr_t OFF_Player_Player     = 0x30;   // APlayerController -> UPlayer*
constexpr uintptr_t OFF_Pawn              = 0x3d0;  // APlayerController -> APawn
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
static uintptr_t g_CachedPlayerController = 0;

// ============================================================================
// [4. LÓGICA DE ESCANEO PASIVO (v7.0)]
// ============================================================================

static void AimlockTick(bool doLog) {
    // ── Heartbeat Obligatorio ──────────────────────────────────────────────
    if (doLog) NSLog(@"[SGLOCK_DEBUG] Tick activo - Boton: %d", g_Active);

    if (!g_Active) {
        g_CachedPlayerController = 0;
        return;
    }

    // ── Validación de Toggle dinámico ShortGun ──────────────────────────────
    bool gameToggle = *reinterpret_cast<bool*>(OFF(TOGGLE_SHORTGUN));
    if (!gameToggle) return;

    // ── Paso 1: Escaneo de GUObjectArray (0x951778) ─────────────────────────
    uintptr_t objArrayBase = OFF(ADDR_GOBJECTS);
    if (!IS_SAFE_PTR(objArrayBase)) return;

    uintptr_t objects = *reinterpret_cast<uintptr_t*>(objArrayBase + 0x10);
    int numObjects = *reinterpret_cast<int*>(objArrayBase + 0x18);
    
    if (!IS_SAFE_PTR(objects) || numObjects <= 0) return;

    // Buscar el PlayerController si no está en caché
    if (!IS_SAFE_PTR(g_CachedPlayerController)) {
        int scanLimit = (numObjects > 20000) ? 20000 : numObjects;
        for (int i = 0; i < scanLimit; i++) {
            uintptr_t item = *reinterpret_cast<uintptr_t*>(objects + (i * 24));
            if (!IS_SAFE_PTR(item)) continue;

            // Identificación por estructura: PlayerController tiene un UPlayer* en 0x30
            uintptr_t player = *reinterpret_cast<uintptr_t*>(item + OFF_Player_Player);
            if (IS_SAFE_PTR(player)) {
                g_CachedPlayerController = item;
                NSLog(@"[SGLOCK_DEBUG] Jugador encontrado (Controller): 0x%lX", item);
                break;
            }
        }
    }

    if (!IS_SAFE_PTR(g_CachedPlayerController)) return;

    // ── Paso 2: Localizar Enemigo más cercano ───────────────────────────────
    uintptr_t myPawn = *reinterpret_cast<uintptr_t*>(g_CachedPlayerController + OFF_Pawn);
    if (!IS_SAFE_PTR(myPawn)) return;

    uintptr_t myRoot = *reinterpret_cast<uintptr_t*>(myPawn + OFF_RootComp);
    if (!IS_SAFE_PTR(myRoot)) return;
    FVector myPos = *reinterpret_cast<FVector*>(myRoot + OFF_RelativeLoc);

    uintptr_t bestEnemy = 0;
    float minDist = 999999.0f;

    // Escaneo rápido de actores
    for (int i = 0; i < 15000 && i < numObjects; i++) {
        uintptr_t item = *reinterpret_cast<uintptr_t*>(objects + (i * 24));
        if (!IS_SAFE_PTR(item) || item == myPawn) continue;

        uintptr_t root = *reinterpret_cast<uintptr_t*>(item + OFF_RootComp);
        if (!IS_SAFE_PTR(root)) continue;

        FVector enPos = *reinterpret_cast<FVector*>(root + OFF_RelativeLoc);
        float d = myPos.Dist(enPos);
        if (d < minDist && d > 50.0f) { // d > 50.0f para ignorar items/props cercanos
            minDist = d;
            bestEnemy = item;
        }
    }

    if (!IS_SAFE_PTR(bestEnemy)) return;

    // ── Paso 3: Cálculo y Escritura Directa ─────────────────────────────────
    uintptr_t enRoot = *reinterpret_cast<uintptr_t*>(bestEnemy + OFF_RootComp);
    FVector targetPos = *reinterpret_cast<FVector*>(enRoot + OFF_RelativeLoc);
    FRotator tgtRot = VecToRot(targetPos - myPos);

    // Lee el offset dinámico de rotación (PAC-SAFE)
    uintptr_t dynamicRotOffset = *reinterpret_cast<uintptr_t*>(OFF(ADDR_ROT_BASE_OFF));
    if (dynamicRotOffset > 0 && dynamicRotOffset < 0x2000) {
        uintptr_t rotAddr = g_CachedPlayerController + dynamicRotOffset;
        if (IS_SAFE_PTR(rotAddr)) {
            *reinterpret_cast<FRotator*>(rotAddr) = tgtRot;
            if (doLog) NSLog(@"[SGLOCK_DEBUG] Aimlock aplicado: 0x%lX", rotAddr);
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
static int g_LogCounter = 0;

- (void)start {
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSLog(@"[SGLOCK_DEBUG] v7.0 Modo Escaneo Pasivo Iniciado.");
}

- (void)onFrame:(CADisplayLink*)link {
    bool doLog = (++g_LogCounter >= 60);
    if (doLog) g_LogCounter = 0;
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
    NSLog(@"[SGLOCK_DEBUG] TOGGLE MANUAL: %d", g_Active);
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
        btn.layer.borderWidth = 2;
        btn.layer.borderColor = UIColor.whiteColor.CGColor;
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
    // Delay de 10s para estabilidad
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InjectUI();
        NSLog(@"[SGLOCK_DEBUG] Heartbeat v7.0 Online.");
    });
}