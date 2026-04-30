#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>
#include <thread>
#include <chrono>
#include <cstring>

// ============================================================================
// [1. ESTRUCTURAS MATEMÁTICAS]
// ============================================================================

struct FVector {
    float X, Y, Z;
    FVector operator-(const FVector& o) const { return {X-o.X, Y-o.Y, Z-o.Z}; }
};

struct FRotator { float Pitch, Yaw, Roll; };

static FRotator VecToRot(FVector d) {
    return {
        atan2f(d.Z, sqrtf(d.X*d.X + d.Y*d.Y)) * (180.f / (float)M_PI),
        atan2f(d.Y, d.X)                        * (180.f / (float)M_PI),
        0.f
    };
}

static float NormAxis(float a) {
    while (a >  180.f) a -= 360.f;
    while (a < -180.f) a += 360.f;
    return a;
}

// ============================================================================
// [2. TRUTH TABLE v4.5 — INVOCACIÓN NATIVA DINÁMICA]
// ============================================================================

// Función de resolución dinámica
constexpr uintptr_t OFF_GET_WORLD         = 0xaf18;   // GetFullWorld()

// Funciones nativas de combate
constexpr uintptr_t OFF_GET_WEAPON_ID     = 0x4c546c;
constexpr uintptr_t OFF_PICK_TARGET       = 0x0b27f0;
constexpr uintptr_t OFF_K2_ACTOR_LOC      = 0x1b844c;
constexpr uintptr_t OFF_ADD_YAW           = 0x1e3294;
constexpr uintptr_t OFF_ADD_PITCH         = 0x1e33dc;

// Jerarquía Unreal Engine
constexpr uintptr_t OFF_GAME_INSTANCE     = 0x180;
constexpr uintptr_t OFF_LOCAL_PLAYERS     = 0x38;
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;

// Offsets de combate
constexpr uintptr_t OFF_HEALTH_STATE      = 0x67c;
constexpr uintptr_t OFF_CTRL_ROTATION     = 0x2e8;
constexpr int       STATE_KNOCKED         = 0x92f92;
constexpr float     SMOOTH                = 0.5f;

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

static bool g_Active    = false;
static int  g_LogTick   = 0; 

static uintptr_t (*GetFullWorld)(void);
static int       (*GetWeaponID)(void*);
static uintptr_t (*PickTarget)(void*, void*, double);
static FVector   (*K2_GetActorLocation)(uintptr_t);
static void      (*AddYaw)(void*, float);
static void      (*AddPitch)(void*, float);

// ============================================================================
// [4. LÓGICA DE COMBATE (Dynamic World Invocation)]
// ============================================================================

static void AimlockTick(bool doLog) {
    if (!g_Active) return;

    // ── Paso 1: Obtener Mundo Vía Función Nativa (0xAF18) ───────────────────
    if (!GetFullWorld) return;
    uintptr_t world = GetFullWorld();
    
    if (!IS_SAFE_PTR(world)) {
        if (doLog) NSLog(@"[SGLOCK_DEBUG] Esperando inicializacion del Mundo...");
        return;
    }
    if (doLog) NSLog(@"[SGLOCK_DEBUG] GWorld resuelto dinamicamente: 0x%lX", world);

    // ── Paso 2: GameInstance (+0x180) ────────────────────────────────────────
    uintptr_t gi = *reinterpret_cast<uintptr_t*>(world + OFF_GAME_INSTANCE);
    if (!IS_SAFE_PTR(gi)) { if (doLog) NSLog(@"[SGLOCK_DEBUG] FAIL: GameInstance nulo."); return; }

    // ── Paso 3: LocalPlayers (+0x38) ─────────────────────────────────────────
    uintptr_t lpArr = *reinterpret_cast<uintptr_t*>(gi + OFF_LOCAL_PLAYERS);
    if (!IS_SAFE_PTR(lpArr)) { if (doLog) NSLog(@"[SGLOCK_DEBUG] FAIL: LocalPlayerArray nulo."); return; }

    // ── Paso 4: LocalPlayer[0] ───────────────────────────────────────────────
    uintptr_t lp = *reinterpret_cast<uintptr_t*>(lpArr);
    if (!IS_SAFE_PTR(lp)) { if (doLog) NSLog(@"[SGLOCK_DEBUG] FAIL: LocalPlayer[0] nulo."); return; }
    if (doLog) NSLog(@"[SGLOCK_DEBUG] LocalPlayer: 0x%lX", lp);

    // ── Paso 5: PlayerController (+0x30) ─────────────────────────────────────
    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + OFF_PLAYER_CTRL);
    if (!IS_SAFE_PTR(ctrl)) { if (doLog) NSLog(@"[SGLOCK_DEBUG] FAIL: PlayerController nulo."); return; }
    if (doLog) NSLog(@"[SGLOCK_DEBUG] Controller: 0x%lX", ctrl);

    // ── Paso 6: Filtro de Arma ───────────────────────────────────────────────
    int wid = GetWeaponID(reinterpret_cast<void*>(lp));
    bool isShotgun = (((wid - 0x19641) < 4) || (wid == 0x196a5));
    if (doLog) NSLog(@"[SGLOCK_DEBUG] WeaponID: 0x%X | isShotgun: %s", (unsigned)wid, isShotgun ? "SI" : "NO");
    if (!isShotgun) return;

    // ── Paso 7: Buscar Objetivo (FOV=90) ─────────────────────────────────────
    uint8_t p1[16] = {}, p2[16] = {};
    uintptr_t enemy = PickTarget(p1, p2, 90.0);
    if (!IS_SAFE_PTR(enemy)) {
        if (doLog) NSLog(@"[SGLOCK_DEBUG] Sin objetivos en FOV.");
        return;
    }

    // ── Paso 8: Cálculo y Ejecución ──────────────────────────────────────────
    int hp = *reinterpret_cast<int*>(enemy + OFF_HEALTH_STATE);
    if (hp == STATE_KNOCKED) return;

    FVector myPos = K2_GetActorLocation(lp);
    FVector enPos = K2_GetActorLocation(enemy);
    FRotator tgt  = VecToRot(enPos - myPos);
    FRotator cur  = *reinterpret_cast<FRotator*>(ctrl + OFF_CTRL_ROTATION);

    float dY = NormAxis(tgt.Yaw   - cur.Yaw);
    float dP = NormAxis(tgt.Pitch - cur.Pitch);

    if (AddYaw && AddPitch) {
        constexpr float TEST_SMOOTH = SMOOTH * 2.0f;
        AddYaw  (reinterpret_cast<void*>(ctrl), dY * TEST_SMOOTH);
        AddPitch(reinterpret_cast<void*>(ctrl), dP * TEST_SMOOTH);
        if (doLog) NSLog(@"[SGLOCK_DEBUG] AddInput -> P:%.2f Y:%.2f", dP * TEST_SMOOTH, dY * TEST_SMOOTH);
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
- (void)start {
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    self.displayLink.preferredFramesPerSecond = 60;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSLog(@"[SGLOCK_DEBUG] CADisplayLink activo.");
}
- (void)onFrame:(CADisplayLink*)link {
    bool doLog = (++g_LogTick >= 60);
    if (doLog) {
        g_LogTick = 0;
        NSLog(@"[SGLOCK_DEBUG] Ciclo activo. Boton estado: %d", g_Active);
    }
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
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen prepare]; [gen impactOccurred];
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
    NSLog(@"[SGLOCK_DEBUG] TOGGLE: %s", g_Active ? "ENABLED" : "DISABLED");
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
        btn.layer.borderWidth = 2;
        btn.layer.borderColor = UIColor.whiteColor.CGColor;
        btn.clipsToBounds = YES;
        btn.alpha = 0.85f;
        [btn addTarget:btn action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(pan:)];
        [btn addGestureRecognizer:pan];
        [win addSubview:btn];

        g_Driver = [[SGLockDriver alloc] init];
        [g_Driver start];
        NSLog(@"[SGLOCK_DEBUG] UI + Driver listos.");
    });
}

// ============================================================================
// [7. INICIALIZACIÓN]
// ============================================================================

static void StartupThread() {
    NSLog(@"[SGLOCK_DEBUG] DYLIB CARGADO. Base: 0x%llX", (unsigned long long)BASE());

    std::this_thread::sleep_for(std::chrono::seconds(10));

    // Resolución de Invocación Nativa
    GetFullWorld        = reinterpret_cast<uintptr_t(*)(void)>            (OFF(OFF_GET_WORLD));
    
    // Resolución de Funciones de Combate
    GetWeaponID         = reinterpret_cast<int(*)(void*)>                 (OFF(OFF_GET_WEAPON_ID));
    PickTarget          = reinterpret_cast<uintptr_t(*)(void*,void*,double)>(OFF(OFF_PICK_TARGET));
    K2_GetActorLocation = reinterpret_cast<FVector(*)(uintptr_t)>          (OFF(OFF_K2_ACTOR_LOC));
    AddYaw              = reinterpret_cast<void(*)(void*,float)>           (OFF(OFF_ADD_YAW));
    AddPitch            = reinterpret_cast<void(*)(void*,float)>           (OFF(OFF_ADD_PITCH));

    NSLog(@"[SGLOCK_DEBUG] Funciones resueltas. Inyectando UI...");
    InjectUI();
}

__attribute__((constructor))
static void init() {
    if (!_dyld_get_image_header(0)) return;
    std::thread(StartupThread).detach();
}
