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
// [2. SISTEMA DE LOCALIZACIÓN DE BINARIO (BYPASS ASLR)]
// ============================================================================

static uintptr_t g_BaseAddress = 0;

static uintptr_t GetBaseAddress() {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "ShadowTrackerExtra")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return (uintptr_t)_dyld_get_image_header(0);
}

static inline uintptr_t OFF(uintptr_t o) { return g_BaseAddress + o; }

// ============================================================================
// [3. TRUTH TABLE v10.0 — SDK INITIALIZATION (GUObjectArray Scan)]
// ============================================================================

constexpr uintptr_t ADDR_GOBJECTS         = 0x951778; // GUObjectArray Maestro
constexpr uintptr_t ADDR_LOCAL_PLAYER_PTR = 0x951788; // _g_LocalPlayer
constexpr uintptr_t ADDR_ROT_BASE_OFF     = 0x951658; // Offset dinámico de rotación
constexpr uintptr_t TOGGLE_SHORTGUN       = 0x9516b2; // bool _ShortGunWP

// Offsets de Clase (UE4 Standard)
constexpr uintptr_t OFF_PersistentLevel   = 0x30;
constexpr uintptr_t OFF_ActorsArray       = 0x98;
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;
constexpr uintptr_t OFF_Pawn              = 0x3d0;
constexpr uintptr_t OFF_RootComp          = 0x130;
constexpr uintptr_t OFF_RelativeLoc       = 0x11c;

#define IS_VALID_PTR(p)    ((uintptr_t)(p) > 0x100000000ULL)
#define IS_SAFE_PTR(p)     (IS_VALID_PTR(p) && (((uintptr_t)(p) & 0x7) == 0))

static bool g_Active = false;
static uintptr_t g_CachedWorld = 0;
static uintptr_t g_CachedPlayer = 0;

// ============================================================================
// [4. LÓGICA DE ESCANEO (findEssentials)]
// ============================================================================

static void findEssentials() {
    uintptr_t objArrayBase = OFF(ADDR_GOBJECTS);
    if (!IS_SAFE_PTR(objArrayBase)) return;

    uintptr_t objects = *reinterpret_cast<uintptr_t*>(objArrayBase + 0x10);
    int numObjects = *reinterpret_cast<int*>(objArrayBase + 0x18);
    
    if (!IS_SAFE_PTR(objects) || numObjects <= 0) return;

    // Escaneo de los primeros 10,000 objetos para inicializar el SDK
    int scanLimit = (numObjects > 10000) ? 10000 : numObjects;
    
    uintptr_t foundWorld = 0;
    uintptr_t foundPlayer = 0;

    for (int i = 0; i < scanLimit; i++) {
        uintptr_t obj = *reinterpret_cast<uintptr_t*>(objects + (i * 24));
        if (!IS_SAFE_PTR(obj)) continue;

        // Heurística de Mundo: Tiene un PersistentLevel en 0x30 y no es un Actor
        uintptr_t level = *reinterpret_cast<uintptr_t*>(obj + OFF_PersistentLevel);
        if (IS_SAFE_PTR(level)) {
            uintptr_t actors = *reinterpret_cast<uintptr_t*>(level + OFF_ActorsArray);
            if (IS_SAFE_PTR(actors)) {
                foundWorld = obj;
            }
        }

        // Heurística de Jugador: Se encuentra en ADDR_LOCAL_PLAYER_PTR como fallback
        if (i == 0) { // Check once
            uintptr_t lpPtr = *reinterpret_cast<uintptr_t*>(OFF(ADDR_LOCAL_PLAYER_PTR));
            if (IS_SAFE_PTR(lpPtr)) foundPlayer = lpPtr;
        }

        if (foundWorld && foundPlayer) break;
    }

    if (foundWorld && foundPlayer) {
        if (g_CachedWorld != foundWorld || g_CachedPlayer != foundPlayer) {
            g_CachedWorld = foundWorld;
            g_CachedPlayer = foundPlayer;
            NSLog(@"[SGLOCK] SDK Inicializado. Mundo: %p | Jugador: %p", (void*)g_CachedWorld, (void*)g_CachedPlayer);
        }
    }
}

static void AimlockTick(bool doLog) {
    if (doLog) NSLog(@"[SGLOCK] Heartbeat - Ciclo vivo. Toggle: %d", g_Active);
    
    // ── Paso 1: Inicializar SDK dinámicamente ───────────────────────────────
    findEssentials();

    if (!g_Active) return;

    // ── Paso 2: Validación de Toggle dinámico ShortGun ──────────────────────
    bool gameToggle = *reinterpret_cast<bool*>(OFF(TOGGLE_SHORTGUN));
    if (!gameToggle) return;

    // ── Paso 3: Obtener Controller y Pawn ───────────────────────────────────
    if (!IS_SAFE_PTR(g_CachedWorld) || !IS_SAFE_PTR(g_CachedPlayer)) return;

    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(g_CachedPlayer + OFF_PLAYER_CTRL);
    if (!IS_SAFE_PTR(ctrl)) return;

    uintptr_t myPawn = *reinterpret_cast<uintptr_t*>(ctrl + OFF_Pawn);
    if (!IS_SAFE_PTR(myPawn)) return;

    // ── Paso 4: Escaneo de Actores ──────────────────────────────────────────
    uintptr_t level = *reinterpret_cast<uintptr_t*>(g_CachedWorld + OFF_PersistentLevel);
    if (!IS_SAFE_PTR(level)) return;

    uintptr_t actorsData = *reinterpret_cast<uintptr_t*>(level + OFF_ActorsArray);
    int actorsCount = *reinterpret_cast<int*>(level + OFF_ActorsArray + 0x8);
    if (!IS_SAFE_PTR(actorsData) || actorsCount <= 0) return;

    uintptr_t myRoot = *reinterpret_cast<uintptr_t*>(myPawn + OFF_RootComp);
    FVector myPos = *reinterpret_cast<FVector*>(myRoot + OFF_RelativeLoc);

    uintptr_t bestEnemy = 0;
    float minDist = 999999.0f;

    for (int i = 0; i < actorsCount && i < 3000; i++) {
        uintptr_t actor = *reinterpret_cast<uintptr_t*>(actorsData + (i * 8));
        if (!IS_SAFE_PTR(actor) || actor == myPawn) continue;

        uintptr_t root = *reinterpret_cast<uintptr_t*>(actor + OFF_RootComp);
        if (!IS_SAFE_PTR(root)) continue;

        FVector enPos = *reinterpret_cast<FVector*>(root + OFF_RelativeLoc);
        float d = myPos.Dist(enPos);
        if (d > 500.0f && d < 50000.0f && d < minDist) {
            minDist = d;
            bestEnemy = actor;
        }
    }

    if (!IS_SAFE_PTR(bestEnemy)) return;

    // ── Paso 5: Escritura de Rotación (PAC-SAFE) ────────────────────────────
    uintptr_t enRoot = *reinterpret_cast<uintptr_t*>(bestEnemy + OFF_RootComp);
    FVector enPos = *reinterpret_cast<FVector*>(enRoot + OFF_RelativeLoc);
    FRotator tgtRot = VecToRot({enPos.X - myPos.X, enPos.Y - myPos.Y, enPos.Z - myPos.Z});

    uintptr_t dynamicRotOffset = *reinterpret_cast<uintptr_t*>(OFF(ADDR_ROT_BASE_OFF));
    if (dynamicRotOffset > 0 && dynamicRotOffset < 0x2000) {
        uintptr_t rotAddr = ctrl + dynamicRotOffset;
        if (IS_SAFE_PTR(rotAddr)) {
            *reinterpret_cast<FRotator*>(rotAddr) = tgtRot;
            if (doLog) NSLog(@"[SGLOCK] Lock Aplicado: En(%.0f,%.0f)", enPos.X, enPos.Y);
        }
    }
}

// ============================================================================
// [5. INTERFAZ Y DRIVER (NSTimer)]
// ============================================================================

@interface SGLockButton : UIButton
@end
@implementation SGLockButton
- (void)toggle {
    g_Active = !g_Active;
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
}
@end

static int g_LogCounter = 0;
static void TimerTick(NSTimer *timer) {
    bool doLog = (++g_LogCounter >= 20);
    if (doLog) g_LogCounter = 0;
    AimlockTick(doLog);
}

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

        NSTimer *timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer * _Nonnull t) {
            TimerTick(t);
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        NSLog(@"[SGLOCK] UI + NSTimer Programados.");
    });
}

__attribute__((constructor))
static void init() {
    g_BaseAddress = GetBaseAddress();
    NSLog(@"[SGLOCK] v10.0 iniciada. Base Address: 0x%llX", (unsigned long long)g_BaseAddress);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InjectUI();
    });
}