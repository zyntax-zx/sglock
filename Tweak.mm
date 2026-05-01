#import <UIKit/UIKit.h>
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
// [2. TRUTH TABLE v16.0 — 'SGLOCK_FINAL' (Architecture v7.0 Clone)]
// ============================================================================

// Offsets confirmados v2.0
constexpr uintptr_t ADDR_GEWORLD           = 0x951768; 
constexpr uintptr_t ADDR_LOCAL_PLAYER_PTR  = 0x951788;
constexpr uintptr_t ADDR_ROT_BASE_OFF      = 0x951658; 

// Offsets de Funciones Nativas (PAC-Safe)
constexpr uintptr_t FUNC_ADD_YAW           = 0x1e3294;
constexpr uintptr_t FUNC_ADD_PITCH         = 0x1e33dc;

// Jerarquía de Datos
constexpr uintptr_t OFF_PersistentLevel    = 0x30;
constexpr uintptr_t OFF_ActorsArray        = 0x98;
constexpr uintptr_t OFF_PLAYER_CTRL        = 0x30;
constexpr uintptr_t OFF_Pawn               = 0x3d0;
constexpr uintptr_t OFF_RootComp           = 0x130;
constexpr uintptr_t OFF_RelativeLoc        = 0x11c;
constexpr uintptr_t OFF_CurrentWeapon      = 0x7a8;
constexpr uintptr_t OFF_WeaponID           = 0xcc;

#define IS_SAFE_PTR(p)     ((uintptr_t)(p) > 0x100000000ULL && ((uintptr_t)(p) & 0x7) == 0)

static bool g_Active = false;
static uintptr_t g_Base = 0;

static inline uintptr_t OFF(uintptr_t o) { return g_Base + o; }

// ============================================================================
// [3. LÓGICA DE AIMLOCK (FINAL SYNC)]
// ============================================================================

static void AimlockTick(bool doLog) {
    if (!g_Active) return;

    // 1. Obtener GWorld (0x951768)
    uintptr_t world = *reinterpret_cast<uintptr_t*>(OFF(ADDR_GEWORLD));
    if (doLog) NSLog(@"[SGLOCK_FINAL] GWorld: %p", (void*)world);
    if (!IS_SAFE_PTR(world)) return;

    // 2. Obtener LocalPlayer (0x951788)
    uintptr_t lp = *reinterpret_cast<uintptr_t*>(OFF(ADDR_LOCAL_PLAYER_PTR));
    if (!IS_SAFE_PTR(lp)) return;

    // 3. Filtro de Escopeta (Lectura Directa 0xCC)
    uintptr_t weapon = *reinterpret_cast<uintptr_t*>(lp + OFF_CurrentWeapon);
    if (IS_SAFE_PTR(weapon)) {
        int wid = *reinterpret_cast<int*>(weapon + OFF_WeaponID);
        bool isShotgun = (((wid - 0x19641) < 4) || (wid == 0x196a5));
        if (doLog) NSLog(@"[SGLOCK_FINAL] WeaponID: 0x%X | isShotgun: %d", wid, isShotgun);
        if (!isShotgun) return;
    } else return;

    // 4. Obtener Controller y Enemigo
    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + OFF_PLAYER_CTRL);
    if (!IS_SAFE_PTR(ctrl)) return;

    uintptr_t myPawn = *reinterpret_cast<uintptr_t*>(ctrl + OFF_Pawn);
    if (!IS_SAFE_PTR(myPawn)) return;

    uintptr_t level = *reinterpret_cast<uintptr_t*>(world + OFF_PersistentLevel);
    uintptr_t actors = *reinterpret_cast<uintptr_t*>(level + OFF_ActorsArray);
    int count = *reinterpret_cast<int*>(level + OFF_ActorsArray + 0x8);

    if (!IS_SAFE_PTR(actors) || count <= 0) return;

    FVector myPos = *reinterpret_cast<FVector*>(*reinterpret_cast<uintptr_t*>(myPawn + OFF_RootComp) + OFF_RelativeLoc);
    uintptr_t bestEnemy = 0;
    float minDist = 999999.0f;

    for (int i = 0; i < count && i < 2000; i++) {
        uintptr_t actor = *reinterpret_cast<uintptr_t*>(actors + (i * 8));
        if (!IS_SAFE_PTR(actor) || actor == myPawn) continue;

        uintptr_t root = *reinterpret_cast<uintptr_t*>(actor + OFF_RootComp);
        if (!IS_SAFE_PTR(root)) continue;

        FVector enPos = *reinterpret_cast<FVector*>(root + OFF_RelativeLoc);
        float d = myPos.Dist(enPos);
        if (d > 500.0f && d < 30000.0f && d < minDist) {
            minDist = d;
            bestEnemy = actor;
        }
    }

    if (IS_SAFE_PTR(bestEnemy)) {
        FVector enPos = *reinterpret_cast<FVector*>(*reinterpret_cast<uintptr_t*>(bestEnemy + OFF_RootComp) + OFF_RelativeLoc);
        FRotator tgtRot = VecToRot({enPos.X - myPos.X, enPos.Y - myPos.Y, enPos.Z - myPos.Z});
        
        // Aplicar Movimiento via Funciones Nativas con Suavizado 0.5f
        void (*AddYaw)(void*, float)   = (void(*)(void*, float))OFF(FUNC_ADD_YAW);
        void (*AddPitch)(void*, float) = (void(*)(void*, float))OFF(FUNC_ADD_PITCH);
        
        // Cálculo de deltas simple
        float curYaw = *reinterpret_cast<float*>(ctrl + 0x2ec); // Offset rotación estándar
        float dY = tgtRot.Yaw - curYaw;
        if (dY > 180.0f) dY -= 360.0f;
        if (dY < -180.0f) dY += 360.0f;

        if (AddYaw && AddPitch) {
            AddYaw((void*)ctrl, dY * 0.5f);
            if (doLog) NSLog(@"[SGLOCK_FINAL] Movimiento aplicado!");
        }
    }
}

// ============================================================================
// [4. INTERFAZ Y DRIVER]
// ============================================================================

@interface SGLockButton : UIButton
@end
@implementation SGLockButton
- (void)toggle {
    g_Active = !g_Active;
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
    NSLog(@"[SGLOCK_FINAL] Toggle: %d", g_Active);
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

        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t){
            static int c = 0;
            AimlockTick(++c >= 40);
            if (c >= 40) c = 0;
        }];
        NSLog(@"[SGLOCK_FINAL] UI y Timer listos.");
    });
}

__attribute__((constructor))
static void init() {
    // Jailed-Safe: Binario principal siempre es el indice 0
    g_Base = _dyld_get_image_vmaddr_slide(0) + 0x100000000;
    NSLog(@"[SGLOCK_FINAL] Tweak cargado. Base detectada: 0x%llX", (unsigned long long)g_Base);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InjectUI();
    });
}