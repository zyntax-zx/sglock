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
    float Dist(const FVector& o) const {
        return sqrtf((X-o.X)*(X-o.X) + (Y-o.Y)*(Y-o.Y) + (Z-o.Z)*(Z-o.Z));
    }
};

struct FRotator { float Pitch, Yaw, Roll; };

static FRotator VecToRot(FVector d) {
    float radToDeg = 180.f / (float)M_PI;
    return {
        atan2f(d.Z, sqrtf(d.X*d.X + d.Y*d.Y)) * radToDeg,
        atan2f(d.Y, d.X)                        * radToDeg,
        0.f
    };
}

// ============================================================================
// [2. TRUTH TABLE v8.0 — MODO CHOQUE (SIN FILTROS)]
// ============================================================================

constexpr uintptr_t ADDR_GWORLD           = 0x951770; 
constexpr uintptr_t ADDR_ROT_BASE_OFF     = 0x951658; 

// Offsets de Navegación Cruda (GWorld -> Actors)
constexpr uintptr_t OFF_PersistentLevel   = 0x30;   // UWorld -> ULevel
constexpr uintptr_t OFF_ActorsArray       = 0x98;   // ULevel -> TArray<AActor*>
constexpr uintptr_t OFF_GAME_INSTANCE     = 0x180;
constexpr uintptr_t OFF_LOCAL_PLAYERS     = 0x38;
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;
constexpr uintptr_t OFF_Pawn              = 0x3d0;
constexpr uintptr_t OFF_RootComp          = 0x130;
constexpr uintptr_t OFF_RelativeLoc       = 0x11c;

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
// [4. LÓGICA DE AIMLOCK (MODO CHOQUE)]
// ============================================================================

static void AimlockTick(bool doLog) {
    if (!g_Active) return;

    // ── Paso 1: Navegación de GWorld para obtener Controller y Pawn ─────────
    uintptr_t worldAddr = *reinterpret_cast<uintptr_t*>(OFF(ADDR_GWORLD));
    if (!IS_SAFE_PTR(worldAddr)) return;

    uintptr_t gi = *reinterpret_cast<uintptr_t*>(worldAddr + OFF_GAME_INSTANCE);
    if (!IS_SAFE_PTR(gi)) return;

    uintptr_t lpArr = *reinterpret_cast<uintptr_t*>(gi + OFF_LOCAL_PLAYERS);
    if (!IS_SAFE_PTR(lpArr)) return;

    uintptr_t lp = *reinterpret_cast<uintptr_t*>(lpArr);
    if (!IS_SAFE_PTR(lp)) return;

    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + OFF_PLAYER_CTRL);
    if (!IS_SAFE_PTR(ctrl)) return;
    if (doLog) NSLog(@"!!! [SGLOCK] TENGO EL CONTROLADOR EN 0x%lX !!!", ctrl);

    uintptr_t myPawn = *reinterpret_cast<uintptr_t*>(ctrl + OFF_Pawn);
    if (!IS_SAFE_PTR(myPawn)) return;

    // ── Paso 2: Escaneo de Actores vía PersistentLevel ──────────────────────
    uintptr_t level = *reinterpret_cast<uintptr_t*>(worldAddr + OFF_PersistentLevel);
    if (!IS_SAFE_PTR(level)) return;

    uintptr_t actorsData = *reinterpret_cast<uintptr_t*>(level + OFF_ActorsArray);
    int actorsCount = *reinterpret_cast<int*>(level + OFF_ActorsArray + 0x8);
    
    if (!IS_SAFE_PTR(actorsData) || actorsCount <= 0) return;

    // Obtener mi posición
    uintptr_t myRoot = *reinterpret_cast<uintptr_t*>(myPawn + OFF_RootComp);
    if (!IS_SAFE_PTR(myRoot)) return;
    FVector myPos = *reinterpret_cast<FVector*>(myRoot + OFF_RelativeLoc);

    uintptr_t bestEnemy = 0;
    float minDist = 999999.0f;

    for (int i = 0; i < actorsCount && i < 5000; i++) {
        uintptr_t actor = *reinterpret_cast<uintptr_t*>(actorsData + (i * 8));
        if (!IS_SAFE_PTR(actor) || actor == myPawn) continue;

        uintptr_t root = *reinterpret_cast<uintptr_t*>(actor + OFF_RootComp);
        if (!IS_SAFE_PTR(root)) continue;

        FVector enPos = *reinterpret_cast<FVector*>(root + OFF_RelativeLoc);
        float d = myPos.Dist(enPos);
        
        // Filtro de distancia crudo: mas de 5 metros para no apuntar a sí mismo, menos de 500 metros
        if (d > 500.0f && d < 50000.0f && d < minDist) {
            minDist = d;
            bestEnemy = actor;
        }
    }

    if (!IS_SAFE_PTR(bestEnemy)) {
        if (doLog) NSLog(@"[SGLOCK] No hay enemigos validos en el Level.");
        return;
    }

    // ── Paso 3: Cálculo y Escritura Directa ─────────────────────────────────
    uintptr_t enRoot = *reinterpret_cast<uintptr_t*>(bestEnemy + OFF_RootComp);
    FVector enPos = *reinterpret_cast<FVector*>(enRoot + OFF_RelativeLoc);
    
    if (doLog) NSLog(@"[SGLOCK] Mi Pos: (%.0f, %.0f) | Enemigo Pos: (%.0f, %.0f) | Escribiendo Angulo...", 
                     myPos.X, myPos.Y, enPos.X, enPos.Y);

    FRotator tgtRot = VecToRot({enPos.X - myPos.X, enPos.Y - myPos.Y, enPos.Z - myPos.Z});

    // Lee el offset dinámico de rotación (0x951658)
    uintptr_t dynamicRotOffset = *reinterpret_cast<uintptr_t*>(OFF(ADDR_ROT_BASE_OFF));
    if (dynamicRotOffset > 0 && dynamicRotOffset < 0x2000) {
        uintptr_t rotAddr = ctrl + dynamicRotOffset;
        if (IS_SAFE_PTR(rotAddr)) {
            *reinterpret_cast<FRotator*>(rotAddr) = tgtRot;
        }
    }
}

// ============================================================================
// [5. DRIVER Y UI]
// ============================================================================

@interface SGLockDriver : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation SGLockDriver
static int logCounter = 0;
- (void)start {
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSLog(@"[SGLOCK] v8.0 MODO CHOQUE INICIADO.");
}
- (void)onFrame:(CADisplayLink*)link {
    bool doLog = (++logCounter >= 60);
    if (doLog) logCounter = 0;
    AimlockTick(doLog);
}
@end

static SGLockDriver* g_Driver = nil;

@interface SGLockButton : UIButton
@end
@implementation SGLockButton
- (void)toggle {
    g_Active = !g_Active;
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
    NSLog(@"[SGLOCK] TOGGLE MANUAL: %d", g_Active);
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

__attribute__((constructor))
static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InjectUI();
    });
}