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
// [2. TRUTH TABLE v4.1 — SDK PASIVO SINCRONIZADO]
// ============================================================================

constexpr uintptr_t ADDR_GWORLD           = 0x951770;
constexpr uintptr_t ADDR_GOBJECTS         = 0x951778;
constexpr uintptr_t ADDR_LOCAL_PLAYER_PTR = 0x951788;

constexpr uintptr_t OFF_GET_WEAPON_ID     = 0x4c546c;
constexpr uintptr_t OFF_PICK_TARGET       = 0x0b27f0;
constexpr uintptr_t OFF_K2_ACTOR_LOC      = 0x1b844c;
constexpr uintptr_t OFF_ADD_YAW           = 0x1e3294;
constexpr uintptr_t OFF_ADD_PITCH         = 0x1e33dc;

constexpr uintptr_t OFF_GAME_INSTANCE     = 0x180;
constexpr uintptr_t OFF_LOCAL_PLAYERS     = 0x38;
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;
constexpr uintptr_t OFF_HEALTH_STATE      = 0x67c;
constexpr uintptr_t OFF_CTRL_ROTATION     = 0x2e8;
constexpr int       STATE_KNOCKED         = 0x92f92;
constexpr float     SMOOTH                = 0.5f;

// Validación estricta: puntero válido y alineado a 8 bytes
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

static int       (*GetWeaponID)(void*);
static uintptr_t (*PickTarget)(void*, void*, double);
static FVector   (*K2_GetActorLocation)(uintptr_t);
static void      (*AddYaw)(void*, float);
static void      (*AddPitch)(void*, float);

// ============================================================================
// [4. LÓGICA DE COMBATE (Frame Tick — Llamada desde Main Thread)]
// ============================================================================

static void AimlockTick() {
    if (!g_Active) return;

    // Ancla de LocalPlayer — validación rápida antes de navegar GWorld
    uintptr_t lpAddr = OFF(ADDR_LOCAL_PLAYER_PTR);
    if (!IS_SAFE_PTR(lpAddr)) return;
    uintptr_t lpAnchor = *reinterpret_cast<uintptr_t*>(lpAddr);
    if (!IS_SAFE_PTR(lpAnchor)) return;

    // GWorld → GameInstance → LocalPlayers → LocalPlayer → PlayerController
    uintptr_t wAddr = OFF(ADDR_GWORLD);
    if (!IS_SAFE_PTR(wAddr)) return;
    uintptr_t world = *reinterpret_cast<uintptr_t*>(wAddr);
    if (!IS_SAFE_PTR(world)) return;

    uintptr_t gi = *reinterpret_cast<uintptr_t*>(world + OFF_GAME_INSTANCE);
    if (!IS_SAFE_PTR(gi)) return;

    uintptr_t lpArr = *reinterpret_cast<uintptr_t*>(gi + OFF_LOCAL_PLAYERS);
    if (!IS_SAFE_PTR(lpArr)) return;

    uintptr_t lp = *reinterpret_cast<uintptr_t*>(lpArr);
    if (!IS_SAFE_PTR(lp)) return;

    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + OFF_PLAYER_CTRL);
    if (!IS_SAFE_PTR(ctrl)) return;

    // Filtro de Arma
    int wid = GetWeaponID(reinterpret_cast<void*>(lp));
    bool isShotgun = (((wid - 0x19641) < 4) || (wid == 0x196a5));
    if (!isShotgun) return;

    // Buscar Objetivo
    uint8_t p1[16] = {}, p2[16] = {};
    uintptr_t enemy = PickTarget(p1, p2, 0.0);
    if (!IS_SAFE_PTR(enemy)) return;

    int hp = *reinterpret_cast<int*>(enemy + OFF_HEALTH_STATE);
    if (hp == STATE_KNOCKED) return;

    // Cálculo de Rotación
    FVector myPos = K2_GetActorLocation(lp);
    FVector enPos = K2_GetActorLocation(enemy);
    FRotator tgt  = VecToRot(enPos - myPos);
    FRotator cur  = *reinterpret_cast<FRotator*>(ctrl + OFF_CTRL_ROTATION);

    float dY = NormAxis(tgt.Yaw   - cur.Yaw);
    float dP = NormAxis(tgt.Pitch - cur.Pitch);

    if (AddYaw && AddPitch) {
        AddYaw  (reinterpret_cast<void*>(ctrl), dY * SMOOTH);
        AddPitch(reinterpret_cast<void*>(ctrl), dP * SMOOTH);
    }
}

// ============================================================================
// [5. CADISPLAYLINK CONTROLLER (Sincronizado con el frame del dispositivo)]
// ============================================================================

@interface SGLockDriver : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
- (void)start;
- (void)onFrame:(CADisplayLink*)link;
@end

@implementation SGLockDriver

- (void)start {
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(onFrame:)];
    self.displayLink.preferredFramesPerSecond = 60;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                           forMode:NSRunLoopCommonModes];
    printf("[SGLock] CADisplayLink activo (60Hz, Main Thread).\n");
}

- (void)onFrame:(CADisplayLink*)link {
    AimlockTick();
}

@end

static SGLockDriver* g_Driver = nil;

// ============================================================================
// [6. INTERFAZ GRÁFICA NATIVA (UIKit — Main Thread)]
// ============================================================================

@interface SGLockButton : UIButton
@end

@implementation SGLockButton
- (void)toggle {
    g_Active = !g_Active;
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
                                       initWithStyle:UIImpactFeedbackStyleMedium];
    [gen prepare]; [gen impactOccurred];
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
    printf("[SGLock] Toggle: %s\n", g_Active ? "ENABLED" : "DISABLED");
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
        // Botón de Toggle
        UIWindow *win = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows)
            if (w.isKeyWindow) { win = w; break; }
        if (!win) return;

        SGLockButton *btn = [SGLockButton buttonWithType:UIButtonTypeCustom];
        btn.frame              = CGRectMake(20, 100, 44, 44);
        btn.layer.cornerRadius = 22;
        btn.backgroundColor    = UIColor.redColor;
        btn.layer.borderWidth  = 2;
        btn.layer.borderColor  = UIColor.whiteColor.CGColor;
        btn.clipsToBounds      = YES;
        btn.alpha              = 0.85f;
        [btn addTarget:btn action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                        initWithTarget:btn action:@selector(pan:)];
        [btn addGestureRecognizer:pan];
        [win addSubview:btn];

        // Iniciar CADisplayLink en el mismo dispatch para garantizar Main Thread
        g_Driver = [[SGLockDriver alloc] init];
        [g_Driver start];

        printf("[SGLock] UI + CADisplayLink listos.\n");
    });
}

// ============================================================================
// [7. INICIALIZACIÓN — PROTOCOLO QUAD-LOCK]
// ============================================================================

static void StartupThread() {
    printf("[SGLock] Iniciado. Base: 0x%lX\n", BASE());

    // ADDR_GOBJECTS reservado para iteración futura de GUObjectArray
    (void)ADDR_GOBJECTS;

    // FASE 1: Delay absoluto de 10 segundos
    std::this_thread::sleep_for(std::chrono::seconds(10));

    // FASE 2: Resolver punteros de funciones nativas (1 sola vez)
    GetWeaponID         = reinterpret_cast<int(*)(void*)>                 (OFF(OFF_GET_WEAPON_ID));
    PickTarget          = reinterpret_cast<uintptr_t(*)(void*,void*,double)>(OFF(OFF_PICK_TARGET));
    K2_GetActorLocation = reinterpret_cast<FVector(*)(uintptr_t)>          (OFF(OFF_K2_ACTOR_LOC));
    AddYaw              = reinterpret_cast<void(*)(void*,float)>           (OFF(OFF_ADD_YAW));
    AddPitch            = reinterpret_cast<void(*)(void*,float)>           (OFF(OFF_ADD_PITCH));

    printf("[SGLock] Funciones nativas resueltas.\n");

    // FASE 3: Inyectar UI + CADisplayLink (siempre, independiente de todo)
    InjectUI();
}

__attribute__((constructor))
static void init() {
    if (!_dyld_get_image_header(0)) return;
    std::thread(StartupThread).detach();
}
