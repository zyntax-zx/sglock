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
// [2. TRUTH TABLE v5.1 — 'AIM-INSIDE-ESP' (Functional Decompiler Logic)]
// ============================================================================

// Offsets de Funciones Nativas
constexpr uintptr_t FUNC_GET_FULL_WORLD  = 0xaf18;
constexpr uintptr_t FUNC_ADD_YAW         = 0x1e3294;
constexpr uintptr_t FUNC_ADD_PITCH       = 0x1e33dc;
constexpr uintptr_t FUNC_GET_WEAPON_ID   = 0x4c546c;
constexpr uintptr_t FUNC_PICK_TARGET     = 0x0b27f0;
constexpr uintptr_t FUNC_K2_ACTOR_LOC    = 0x1b844c;

// Offsets de Datos (Anclas)
constexpr uintptr_t ADDR_LOCAL_PLAYER    = 0x951788; // _g_LocalPlayer
constexpr uintptr_t TOGGLE_SHORTGUN      = 0x9516b2; // Interruptor dinámico del juego

// Offsets Estándar UE4
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;   // LocalPlayer -> Controller
constexpr uintptr_t OFF_CTRL_ROTATION     = 0x2e8;  // Controller -> Rotation
constexpr uintptr_t OFF_HEALTH_STATE      = 0x67c;
constexpr int       STATE_KNOCKED         = 0x92f92;

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
// [4. LÓGICA DE COMBATE (v5.1 — Sincronizada con el ESP del Autor)]
// ============================================================================

static void AimlockTick(bool doLog) {
    // Paso 1: GWorld dinámico
    if (!GetFullWorld) return;
    uintptr_t world = GetFullWorld();
    if (!IS_SAFE_PTR(world)) {
        if (doLog) NSLog(@"[SGLOCK_DEBUG] GWorld nulo (fuera de partida).");
        return;
    }

    // Paso 2: LocalPlayer desde ancla 0x951788
    uintptr_t lpPtr = OFF(ADDR_LOCAL_PLAYER);
    if (!IS_SAFE_PTR(lpPtr)) return;
    uintptr_t lp = *reinterpret_cast<uintptr_t*>(lpPtr);
    if (!IS_SAFE_PTR(lp)) {
        if (doLog) NSLog(@"[SGLOCK_DEBUG] LocalPlayer nulo.");
        return;
    }

    // Paso 3: Validación de Toggles (Manual + Juego)
    bool gameToggle = *reinterpret_cast<bool*>(OFF(TOGGLE_SHORTGUN));
    if (!g_Active || !gameToggle) return;

    // Paso 4: PlayerController
    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + OFF_PLAYER_CTRL);
    if (!IS_SAFE_PTR(ctrl)) return;

    // Paso 5: Filtro de Arma (0x4c546c)
    int wid = GetWeaponID(reinterpret_cast<void*>(lp));
    bool isShotgun = (((wid - 0x19641) < 4) || (wid == 0x196a5));
    if (doLog) NSLog(@"[SGLOCK_DEBUG] WeaponID: 0x%X | isShotgun: %s", (unsigned)wid, isShotgun ? "SI" : "NO");
    if (!isShotgun) return;

    // Paso 6: Buscar Objetivo (PickTarget 0x0b27f0)
    uint8_t p1[16] = {}, p2[16] = {};
    uintptr_t enemy = PickTarget(p1, p2, 90.0);
    if (!IS_SAFE_PTR(enemy)) {
        if (doLog) NSLog(@"[SGLOCK_DEBUG] Sin objetivos en FOV.");
        return;
    }

    // Paso 7: Cálculo y Movimiento de Mira (Smooth 0.5)
    int hp = *reinterpret_cast<int*>(enemy + OFF_HEALTH_STATE);
    if (hp == STATE_KNOCKED) return;

    FVector myPos = K2_GetActorLocation(lp);
    FVector enPos = K2_GetActorLocation(enemy);
    FRotator tgt  = VecToRot(enPos - myPos);
    FRotator cur  = *reinterpret_cast<FRotator*>(ctrl + OFF_CTRL_ROTATION);

    float dY = NormAxis(tgt.Yaw   - cur.Yaw);
    float dP = NormAxis(tgt.Pitch - cur.Pitch);

    if (AddYaw && AddPitch) {
        // Invocación nativa exacta (val * 0.5)
        AddYaw  (reinterpret_cast<void*>(ctrl), dY * 0.5f);
        AddPitch(reinterpret_cast<void*>(ctrl), dP * 0.5f);
        if (doLog) NSLog(@"[SGLOCK_DEBUG] AddInput Aplicado.");
    }
}

// ============================================================================
// [5. DRIVER DE SINCRONIZACIÓN (CADisplayLink)]
// ============================================================================

@interface SGLockDriver : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation SGLockDriver
- (void)start {
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSLog(@"[SGLOCK_DEBUG] Driver ESP-Sync Activo.");
}
- (void)onFrame:(CADisplayLink*)link {
    bool doLog = (++g_LogTick >= 60);
    if (doLog) {
        g_LogTick = 0;
        NSLog(@"[SGLOCK_DEBUG] Ciclo Activo. Toggle: %d", g_Active);
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
        [btn addTarget:btn action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:btn];

        g_Driver = [[SGLockDriver alloc] init];
        [g_Driver start];
    });
}

// ============================================================================
// [7. INICIALIZACIÓN]
// ============================================================================

static void StartupThread() {
    NSLog(@"[SGLOCK_DEBUG] Iniciando v5.1 'Internal SDK'...");
    std::this_thread::sleep_for(std::chrono::seconds(10));

    // Resolución de funciones nativas
    GetFullWorld        = reinterpret_cast<uintptr_t(*)(void)>            (OFF(FUNC_GET_FULL_WORLD));
    GetWeaponID         = reinterpret_cast<int(*)(void*)>                 (OFF(FUNC_GET_WEAPON_ID));
    PickTarget          = reinterpret_cast<uintptr_t(*)(void*,void*,double)>(OFF(FUNC_PICK_TARGET));
    K2_GetActorLocation = reinterpret_cast<FVector(*)(uintptr_t)>          (OFF(FUNC_K2_ACTOR_LOC));
    AddYaw              = reinterpret_cast<void(*)(void*,float)>           (OFF(FUNC_ADD_YAW));
    AddPitch            = reinterpret_cast<void(*)(void*,float)>           (OFF(FUNC_ADD_PITCH));

    InjectUI();
}

__attribute__((constructor))
static void init() {
    if (!_dyld_get_image_header(0)) return;
    std::thread(StartupThread).detach();
}
