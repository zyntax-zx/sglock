#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>
#include <thread>
#include <chrono>
#include <unistd.h>
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
// [2. TRUTH TABLE v4.0 — SDK PASIVO (Validado en Ghidra)]
// ============================================================================

// Anclas globales del motor
constexpr uintptr_t ADDR_GWORLD           = 0x951770; // _GWorldNum (UWorld*)
constexpr uintptr_t ADDR_GOBJECTS         = 0x951778; // GUObjectArray
constexpr uintptr_t ADDR_LOCAL_PLAYER_PTR = 0x951788; // _g_LocalPlayer

// Funciones nativas del binario (llamadas directas, NO hooks)
constexpr uintptr_t OFF_GET_WEAPON_ID     = 0x4c546c;
constexpr uintptr_t OFF_PICK_TARGET       = 0x0b27f0;
constexpr uintptr_t OFF_K2_ACTOR_LOC      = 0x1b844c;
constexpr uintptr_t OFF_ADD_YAW           = 0x1e3294;
constexpr uintptr_t OFF_ADD_PITCH         = 0x1e33dc;

// Offsets de jerarquía (GWorld → PlayerController)
constexpr uintptr_t OFF_GAME_INSTANCE     = 0x180;
constexpr uintptr_t OFF_LOCAL_PLAYERS     = 0x38;
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;

// Offsets de combate
constexpr uintptr_t OFF_HEALTH_STATE      = 0x67c;
constexpr uintptr_t OFF_CTRL_ROTATION     = 0x2e8;
constexpr int       STATE_KNOCKED         = 0x92f92;

// Suavizado del aimlock
constexpr float     SMOOTH                = 0.5f;

#define IS_VALID_PTR(p) ((uintptr_t)(p) > 0x100000000ULL)

static inline uintptr_t BASE() {
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0));
}
static inline uintptr_t OFF(uintptr_t o) { return BASE() + o; }

// ============================================================================
// [3. ESTADO GLOBAL]
// ============================================================================

static bool g_Active = false;

// ============================================================================
// [4. FIRMAS DE FUNCIONES NATIVAS]
// ============================================================================

static int       (*GetWeaponID)(void*);
static uintptr_t (*PickTarget)(void*, void*, double);
static FVector   (*K2_GetActorLocation)(uintptr_t);
static void      (*AddYaw)(void*, float);
static void      (*AddPitch)(void*, float);

// ============================================================================
// [5. INTERFAZ GRÁFICA NATIVA (UIKit — Main Thread)]
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
        printf("[SGLock] UI Master Switch inyectada.\n");
    });
}

// ============================================================================
// [6. POLLING SDK — NÚCLEO DEL AIMLOCK PASIVO (~60 FPS)]
// ============================================================================

static void PollingLoop() {
    // NOTA: GObjects reservado para futura expansión
    (void)ADDR_GOBJECTS;

    while (true) {
        // ~60 FPS polling tick
        std::this_thread::sleep_for(std::chrono::milliseconds(16));

        // Regla de Oro: 0 trabajo si el toggle está apagado
        if (!g_Active) continue;

        // ── Paso 1: Validación rápida con ancla LocalPlayer ──────────────────
        uintptr_t lpAnchor = *reinterpret_cast<uintptr_t*>(OFF(ADDR_LOCAL_PLAYER_PTR));
        if (!IS_VALID_PTR(lpAnchor)) continue;

        // ── Paso 2: Navegar GWorld → PlayerController ────────────────────────
        uintptr_t world = *reinterpret_cast<uintptr_t*>(OFF(ADDR_GWORLD));
        if (!IS_VALID_PTR(world)) continue;

        uintptr_t gi = *reinterpret_cast<uintptr_t*>(world + OFF_GAME_INSTANCE);
        if (!IS_VALID_PTR(gi)) continue;

        uintptr_t lpArr = *reinterpret_cast<uintptr_t*>(gi + OFF_LOCAL_PLAYERS);
        if (!IS_VALID_PTR(lpArr)) continue;

        uintptr_t lp = *reinterpret_cast<uintptr_t*>(lpArr);
        if (!IS_VALID_PTR(lp)) continue;

        uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + OFF_PLAYER_CTRL);
        if (!IS_VALID_PTR(ctrl)) continue;

        // ── Paso 3: Filtro de Arma (Shotgun Check) ───────────────────────────
        int wid = GetWeaponID(reinterpret_cast<void*>(lp));
        bool isShotgun = (((wid - 0x19641) < 4) || (wid == 0x196a5));
        if (!isShotgun) continue;

        // ── Paso 4: Búsqueda de Objetivo ─────────────────────────────────────
        uint8_t p1[16] = {}, p2[16] = {};
        uintptr_t enemy = PickTarget(p1, p2, 0.0);
        if (!IS_VALID_PTR(enemy)) continue;

        // ── Paso 5: Filtro de Estado (Excluir noqueados) ──────────────────────
        int hp = *reinterpret_cast<int*>(enemy + OFF_HEALTH_STATE);
        if (hp == STATE_KNOCKED) continue;

        // ── Paso 6: Cálculo de Rotación Trigonométrica ────────────────────────
        FVector myPos = K2_GetActorLocation(lp);
        FVector enPos = K2_GetActorLocation(enemy);
        FRotator tgt  = VecToRot(enPos - myPos);
        FRotator cur  = *reinterpret_cast<FRotator*>(ctrl + OFF_CTRL_ROTATION);

        float dY = NormAxis(tgt.Yaw   - cur.Yaw);
        float dP = NormAxis(tgt.Pitch - cur.Pitch);

        // ── Paso 7: Input Nativo Suavizado (Lectura legal, sin escritura directa)
        if (AddYaw && AddPitch) {
            AddYaw  (reinterpret_cast<void*>(ctrl), dY * SMOOTH);
            AddPitch(reinterpret_cast<void*>(ctrl), dP * SMOOTH);
        }
    }
}

// ============================================================================
// [7. INICIALIZACIÓN — PROTOCOLO QUAD-LOCK]
// ============================================================================

static void StartupThread() {
    printf("[SGLock] Iniciado. Base: 0x%lX\n", BASE());

    // FASE 1: Delay absoluto de 10 segundos (Motor + Anti-cheat se estabilizan)
    std::this_thread::sleep_for(std::chrono::seconds(10));

    // FASE 2: Resolver punteros de funciones nativas (1 sola vez)
    GetWeaponID         = reinterpret_cast<int(*)(void*)>         (OFF(OFF_GET_WEAPON_ID));
    PickTarget          = reinterpret_cast<uintptr_t(*)(void*,void*,double)>(OFF(OFF_PICK_TARGET));
    K2_GetActorLocation = reinterpret_cast<FVector(*)(uintptr_t)> (OFF(OFF_K2_ACTOR_LOC));
    AddYaw              = reinterpret_cast<void(*)(void*,float)>  (OFF(OFF_ADD_YAW));
    AddPitch            = reinterpret_cast<void(*)(void*,float)>  (OFF(OFF_ADD_PITCH));

    printf("[SGLock] Funciones nativas resueltas.\n");

    // FASE 3: Inyectar UI (main_queue, siempre, independiente de todo)
    InjectUI();

    // FASE 4: Iniciar bucle de Polling SDK (hilo dedicado, 60 FPS)
    std::thread(PollingLoop).detach();
    printf("[SGLock] Polling SDK activo. Esperando toggle...\n");
}

__attribute__((constructor))
static void init() {
    if (!_dyld_get_image_header(0)) return;
    std::thread(StartupThread).detach();
}
