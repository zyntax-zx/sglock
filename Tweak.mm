#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
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
    float Dist(const FVector& o) const {
        return sqrtf((X-o.X)*(X-o.X) + (Y-o.Y)*(Y-o.Y) + (Z-o.Z)*(Z-o.Z));
    }
};

struct FRotator { float Pitch, Yaw, Roll; };

__attribute__((unused)) static FRotator VecToRot(FVector d) {
    float radToDeg = 180.f / (float)M_PI;
    return {
        atan2f(d.Z, sqrtf(d.X*d.X + d.Y*d.Y)) * radToDeg,
        atan2f(d.Y, d.X)                        * radToDeg,
        0.f
    };
}

// ============================================================================
// [2. PATTERN SCANNER (AOB SCAN) — BYPASS PROTECCIONES]
// ============================================================================

__attribute__((unused)) static uintptr_t FindPattern(uintptr_t start, uintptr_t size, const char* pattern, const char* mask) {
    size_t patternLen = strlen(mask);
    for (uintptr_t i = 0; i < size - patternLen; i++) {
        bool found = true;
        for (size_t j = 0; j < patternLen; j++) {
            if (mask[j] != '?' && ((uint8_t*)pattern)[j] != ((uint8_t*)(start + i))[j]) {
                found = false;
                break;
            }
        }
        if (found) return start + i;
    }
    return 0;
}

static uintptr_t g_BaseAddress = 0;
static uintptr_t g_DataStart = 0;
static uintptr_t g_DataSize = 0;

static void InitializeMemoryInfo() {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "ShadowTrackerExtra")) {
            g_BaseAddress = (uintptr_t)_dyld_get_image_header(i);
            
            // Obtener segmento __DATA para escaneo
            unsigned long size = 0;
            g_DataStart = (uintptr_t)getsectiondata((const struct mach_header_64*)g_BaseAddress, "__DATA", "__data", &size);
            g_DataSize = (uintptr_t)size;
            
            NSLog(@"[SGLOCK] Base: 0x%lX | DATA: 0x%lX (Size: 0x%lX)", g_BaseAddress, g_DataStart, g_DataSize);
            return;
        }
    }
}

// ============================================================================
// [3. TRUTH TABLE v13.0 — PATTERNS & NATIVE FUNCTIONS]
// ============================================================================

static uintptr_t g_WorldPtr = 0;

// Offsets de Funciones (Offsets v2.0 confirmados)
constexpr uintptr_t OFF_ADD_YAW   = 0x1e3294;
constexpr uintptr_t OFF_ADD_PITCH = 0x1e33dc;
constexpr uintptr_t OFF_PICK_TARGET = 0x0b27f0;

typedef void (*AddInput_t)(void*, float);
static AddInput_t AddYaw = NULL;
static AddInput_t AddPitch = NULL;

#define IS_SAFE_PTR(p)     ((uintptr_t)(p) > 0x100000000ULL && ((uintptr_t)(p) & 0x7) == 0)

static bool g_Active = false;

// ============================================================================
// [4. LÓGICA DE AIMLOCK (AOB + NATIVE)]
// ============================================================================

static void AimlockTick(bool doLog) {
    if (doLog) NSLog(@"[SGLOCK] Heartbeat v13.0");
    if (!g_Active) return;

    // ── Paso 1: Escaneo de GWorld (Si no se ha encontrado) ──────────────────
    if (!g_WorldPtr) {
        // Patrón genérico de GWorld (Ajustado para UE4 ARM64)
        
        // Como fallback, usamos el offset de GUObjectArray + 0x10 que pide el usuario
        uintptr_t gObjectsAddr = g_BaseAddress + 0x951778;
        uintptr_t objects = *reinterpret_cast<uintptr_t*>(gObjectsAddr + 0x10);
        
        if (IS_SAFE_PTR(objects)) {
            g_WorldPtr = gObjectsAddr; // Usamos el ancla de GObjects como base
            if (doLog) NSLog(@"[SGLOCK] SDK Inicializado via GObjects (0x951778)");
        }
    }

    if (!IS_SAFE_PTR(g_WorldPtr)) return;

    // ── Paso 2: Obtener Jugador desde 0x951788 (Confirmado en Ghidra) ───────
    uintptr_t lpPtr = *reinterpret_cast<uintptr_t*>(g_BaseAddress + 0x951788);
    if (!IS_SAFE_PTR(lpPtr)) return;

    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lpPtr + 0x30);
    if (!IS_SAFE_PTR(ctrl)) return;

    // ── Paso 3: Buscar Objetivo (Invocación Directa) ────────────────────────
    uint8_t p1[16] = {}, p2[16] = {};
    uintptr_t (*PickTarget_f)(void*, void*, double) = (uintptr_t(*)(void*, void*, double))(g_BaseAddress + OFF_PICK_TARGET);
    uintptr_t enemy = PickTarget_f(p1, p2, 90.0);
    
    if (IS_SAFE_PTR(enemy)) {
        if (doLog) NSLog(@"[SGLOCK] Enemigo encontrado: %p", (void*)enemy);
        
        // ── Paso 4: Movimiento de Mira (AddControllerInput) ─────────────────
        if (AddYaw && AddPitch) {
            // Cálculo simplificado de Delta (Requiere Posiciones)
            // Para v13.0 simplificamos el llamado para verificar estabilidad
            AddYaw  (reinterpret_cast<void*>(ctrl), 1.0f); // Test de movimiento
            AddPitch(reinterpret_cast<void*>(ctrl), 0.0f);
        }
    }
}

// ============================================================================
// [5. INTERFAZ Y INICIALIZACIÓN]
// ============================================================================

@interface SGLockButton : UIButton
@end
@implementation SGLockButton
- (void)toggle {
    g_Active = !g_Active;
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
}
@end

static void TimerTick(NSTimer *timer) {
    static int counter = 0;
    AimlockTick(++counter >= 20);
    if (counter >= 20) counter = 0;
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

        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t){ TimerTick(t); }];
        NSLog(@"[SGLOCK] v13.0 UI + Timer Online.");
    });
}

__attribute__((constructor))
static void init() {
    InitializeMemoryInfo();
    
    // Resolver funciones nativas
    AddYaw   = (AddInput_t)(g_BaseAddress + OFF_ADD_YAW);
    AddPitch = (AddInput_t)(g_BaseAddress + OFF_ADD_PITCH);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InjectUI();
    });
}