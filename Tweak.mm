#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <thread>
#include <chrono>
#include <cstring>

// ============================================================================
// [1. TRUTH TABLE v15.0 — ARQUITECTURA 'PROCESS_EVENT' (SDK CLONE)]
// ============================================================================

// Offsets de Funciones Nativas
constexpr uintptr_t FUNC_GET_FULL_WORLD  = 0xaf18;
constexpr uintptr_t FUNC_GET_WEAPON_ID   = 0x4c546c;
constexpr uintptr_t FUNC_PICK_TARGET     = 0x0b27f0;
constexpr uintptr_t FUNC_ADD_YAW         = 0x1e3294;
constexpr uintptr_t FUNC_ADD_PITCH       = 0x1e33dc;

// Offsets de Datos
constexpr uintptr_t ADDR_GEWORLD         = 0x951768;
constexpr uintptr_t ADDR_LOCAL_PLAYER    = 0x951788;

// Hook Config
constexpr int       IDX_PROCESS_EVENT    = 76;   // VTable Index
constexpr uintptr_t OFF_HUD              = 0x338; // Controller -> MyHUD

#define IS_SAFE_PTR(p)    ((uintptr_t)(p) > 0x100000000ULL && ((uintptr_t)(p) & 0x7) == 0)

static inline uintptr_t BASE() {
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0));
}
static inline uintptr_t OFF(uintptr_t o) { return BASE() + o; }

// ============================================================================
// [2. DEFINICIONES DE TIPOS]
// ============================================================================

struct FName { int Index; int Number; };
struct UObject { void** VTable; };

typedef void (*ProcessEvent_t)(void*, void*, void*);
static ProcessEvent_t orig_ProcessEvent = NULL;

static bool g_Active = false;

// ============================================================================
// [3. LOGICA DEL HOOK (hkProcessEvent)]
// ============================================================================

static void hkProcessEvent(void* obj, void* func, void* params) {
    if (g_Active && func) {
        // Obtenemos el FName del evento (offset 0x18 en UObject/UFunction)
        uint32_t nameIndex = *reinterpret_cast<uint32_t*>((uintptr_t)func + 0x18);
        
        // El ID del evento "ReceiveDrawHUD" suele ser constante tras la carga
        // Aquí replicamos la lógica de filtrado del autor
        static uint32_t hudEventID = 0;
        if (hudEventID == 0 || nameIndex == hudEventID) {
            
            // 1. Obtener Mundo (Invocación Nativa)
            uintptr_t (*GetFullWorld)(void) = (uintptr_t(*)(void))OFF(FUNC_GET_FULL_WORLD);
            uintptr_t world = GetFullWorld();

            if (IS_SAFE_PTR(world)) {
                // 2. Obtener LocalPlayer (Validación)
                uintptr_t lp = *reinterpret_cast<uintptr_t*>(OFF(ADDR_LOCAL_PLAYER));
                
                if (IS_SAFE_PTR(lp)) {
                    // 3. Obtener Arma y Filtro
                    int (*GetWeaponID)(void*) = (int(*)(void*))OFF(FUNC_GET_WEAPON_ID);
                    int wid = GetWeaponID((void*)lp);

                    if (((wid - 0x19641) < 4) || (wid == 0x196a5)) {
                        // 4. Buscar Objetivo
                        uintptr_t (*PickTarget)(void*, void*, double) = (uintptr_t(*)(void*, void*, double))OFF(FUNC_PICK_TARGET);
                        uint8_t p1[16] = {}, p2[16] = {};
                        uintptr_t enemy = PickTarget(p1, p2, 90.0);

                        if (IS_SAFE_PTR(enemy)) {
                            // 5. Aplicar Movimiento
                            uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + 0x30);
                            if (IS_SAFE_PTR(ctrl)) {
                                void (*AddYaw)(void*, float) = (void(*)(void*, float))OFF(FUNC_ADD_YAW);
                                void (*AddPitch)(void*, float) = (void(*)(void*, float))OFF(FUNC_ADD_PITCH);
                                
                                // Aplicamos rotación con smoothing del original (0.5f)
                                // Nota: Para v15 calculamos el delta internamente o confiamos en PickTarget
                                AddYaw((void*)ctrl, 0.5f); 
                                AddPitch((void*)ctrl, 0.1f);
                            }
                        }
                    }
                }
            }
            if (hudEventID == 0) hudEventID = nameIndex;
        }
    }
    orig_ProcessEvent(obj, func, params);
}

// ============================================================================
// [4. MOTOR DE INYECCIÓN (VTABLE SWAP)]
// ============================================================================

static void HookHUD() {
    NSLog(@"[SGLOCK] Intentando VTable Swap sobre HUD...");

    uintptr_t lp = *reinterpret_cast<uintptr_t*>(OFF(ADDR_LOCAL_PLAYER));
    if (!IS_SAFE_PTR(lp)) return;

    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + 0x30);
    if (!IS_SAFE_PTR(ctrl)) return;

    uintptr_t hud = *reinterpret_cast<uintptr_t*>(ctrl + OFF_HUD);
    if (!IS_SAFE_PTR(hud)) return;

    void** vtable = *reinterpret_cast<void***>(hud);
    if (vtable) {
        orig_ProcessEvent = (ProcessEvent_t)vtable[IDX_PROCESS_EVENT];
        
        // Creamos Shadow VTable (Copia de 1024 entradas para seguridad)
        static void* shadowVTable[1024];
        memcpy(shadowVTable, vtable, sizeof(void*) * 1024);
        
        // Reemplazamos entrada
        shadowVTable[IDX_PROCESS_EVENT] = (void*)hkProcessEvent;
        
        // Swapping
        *reinterpret_cast<void***>(hud) = shadowVTable;
        
        NSLog(@"[SGLOCK] HUD Hookeado con exito (VTable Swap).");
    }
}

// ============================================================================
// [5. INTERFAZ Y STARTUP]
// ============================================================================

@interface SGLockButton : UIButton
@end
@implementation SGLockButton
- (void)toggle {
    g_Active = !g_Active;
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
    NSLog(@"[SGLOCK] Aimlock Status: %d", g_Active);
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
        
        // Iniciamos el Hook tras la UI
        HookHUD();
    });
}

__attribute__((constructor))
static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InjectUI();
    });
}