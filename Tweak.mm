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
// [3. TRUTH TABLE v10.1 — TELEMETRÍA DE DIAGNÓSTICO]
// ============================================================================

constexpr uintptr_t ADDR_GWORLD           = 0x951770;
constexpr uintptr_t ADDR_GOBJECTS         = 0x951778; 
constexpr uintptr_t ADDR_LOCAL_PLAYER_PTR = 0x951788; 
constexpr uintptr_t ADDR_ROT_BASE_OFF     = 0x951658; 

// Offsets Estándar
constexpr uintptr_t OFF_PersistentLevel   = 0x30;
constexpr uintptr_t OFF_ActorsArray       = 0x98;
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;
constexpr uintptr_t OFF_Pawn              = 0x3d0;
constexpr uintptr_t OFF_RootComp          = 0x130;
constexpr uintptr_t OFF_RelativeLoc       = 0x11c;

#define IS_VALID_PTR(p)    ((uintptr_t)(p) > 0x100000000ULL)
#define IS_SAFE_PTR(p)     (IS_VALID_PTR(p) && (((uintptr_t)(p) & 0x7) == 0))

static bool g_Active = false;

// ============================================================================
// [4. LÓGICA DE AIMLOCK (MODO DIAGNÓSTICO RUIDOSO)]
// ============================================================================

static void AimlockTick(bool doLog) {
    if (doLog) NSLog(@"[SGLOCK] Heartbeat - Ciclo vivo. Toggle: %d", g_Active);
    if (!g_Active) return;

    // ── Paso 1: Diagnóstico de GObjects ─────────────────────────────────────
    uintptr_t gObjectsBase = OFF(ADDR_GOBJECTS);
    if (doLog) NSLog(@"[SGLOCK] Leyendo GObjects en Base + 0x%lX...", ADDR_GOBJECTS);
    
    uintptr_t objects = *reinterpret_cast<uintptr_t*>(gObjectsBase + 0x10);
    int numObjects = *reinterpret_cast<int*>(gObjectsBase + 0x18);
    if (doLog) NSLog(@"[SGLOCK] GObjects -> %p | Num: %d", (void*)objects, numObjects);

    if (IS_SAFE_PTR(objects) && numObjects > 10 && doLog) {
        for (int i = 0; i < 10; i++) {
            uintptr_t obj = *reinterpret_cast<uintptr_t*>(objects + (i * 24));
            if (IS_SAFE_PTR(obj)) {
                uint32_t fNameIndex = *reinterpret_cast<uint32_t*>(obj + 0x18);
                NSLog(@"[SGLOCK] Obj[%d] -> %p | FNameIndex: 0x%X", i, (void*)obj, fNameIndex);
            }
        }
    }

    // ── Paso 2: Diagnóstico de GWorld ───────────────────────────────────────
    uintptr_t gWorldPtr = *reinterpret_cast<uintptr_t*>(OFF(ADDR_GWORLD));
    if (doLog) NSLog(@"[SGLOCK] GWorld (0x%lX) -> %p", ADDR_GWORLD, (void*)gWorldPtr);
    if (!IS_SAFE_PTR(gWorldPtr)) return;

    // ── Paso 3: Diagnóstico de LocalPlayer ──────────────────────────────────
    uintptr_t lpPtr = *reinterpret_cast<uintptr_t*>(OFF(ADDR_LOCAL_PLAYER_PTR));
    if (doLog) NSLog(@"[SGLOCK] LocalPlayerPtr (0x%lX) -> %p", ADDR_LOCAL_PLAYER_PTR, (void*)lpPtr);
    if (!IS_SAFE_PTR(lpPtr)) return;

    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lpPtr + OFF_PLAYER_CTRL);
    if (doLog) NSLog(@"[SGLOCK] PlayerController -> %p", (void*)ctrl);
    if (!IS_SAFE_PTR(ctrl)) return;

    uintptr_t myPawn = *reinterpret_cast<uintptr_t*>(ctrl + OFF_Pawn);
    if (!IS_SAFE_PTR(myPawn)) return;

    // ── Paso 4: Escaneo de Actores ──────────────────────────────────────────
    uintptr_t level = *reinterpret_cast<uintptr_t*>(gWorldPtr + OFF_PersistentLevel);
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

    // ── Paso 5: Escritura de Rotación ───────────────────────────────────────
    FVector enPos = *reinterpret_cast<FVector*>(*reinterpret_cast<uintptr_t*>(bestEnemy + OFF_RootComp) + OFF_RelativeLoc);
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
    NSLog(@"[SGLOCK] Boton presionado -> %d", g_Active);
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
    NSLog(@"[SGLOCK] Base Address Calculada: %p", (void*)g_BaseAddress);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InjectUI();
    });
}