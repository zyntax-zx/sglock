#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>
#include <thread>
#include <chrono>
#include <sys/mman.h>
#include <unistd.h>
#include <cstring>
#include <dlfcn.h>

// ============================================================================
// [1. ESTRUCTURAS Y MATEMÁTICAS]
// ============================================================================

struct FVector {
    float X, Y, Z;
    FVector operator-(const FVector& Other) const {
        return { X - Other.X, Y - Other.Y, Z - Other.Z };
    }
};

struct FRotator {
    float Pitch, Yaw, Roll;
};

FRotator VectorToRotator(FVector dir) {
    FRotator rot;
    rot.Yaw   = atan2f(dir.Y, dir.X) * (180.0f / M_PI);
    rot.Pitch = atan2f(dir.Z, sqrtf(dir.X * dir.X + dir.Y * dir.Y)) * (180.0f / M_PI);
    rot.Roll  = 0.0f;
    return rot;
}

float NormalizeAxis(float angle) {
    while (angle >  180.f) angle -= 360.f;
    while (angle < -180.f) angle += 360.f;
    return angle;
}

// ============================================================================
// [2. TABLA DE LA VERDAD (Offsets v2.0 — Base 0)]
// ============================================================================

constexpr uintptr_t OFFSET_LOCAL_PLAYER      = 0x951788;
constexpr uintptr_t OFFSET_GET_WEAPON_ID     = 0x4c546c;
constexpr uintptr_t OFFSET_K2_GET_ACTOR_LOC  = 0x1b844c;
constexpr uintptr_t OFFSET_ADD_YAW_INPUT     = 0x1e3294;
constexpr uintptr_t OFFSET_ADD_PITCH_INPUT   = 0x1e33dc;
constexpr uintptr_t OFFSET_PICK_TARGET       = 0x0b27f0;
constexpr uintptr_t ADDRESS_STRING_DRAW_HUD  = 0x90cb2a;
constexpr uintptr_t OFFSET_HEALTH_STATE      = 0x67c;
constexpr uintptr_t OFFSET_PLAYER_CONTROLLER = 0x548;
constexpr uintptr_t OFFSET_CONTROL_ROTATION  = 0x2e8;

constexpr int       STATE_KNOCKED            = 0x92f92;

#define IS_VALID_PTR(p) ((uintptr_t)(p) > 0x100000000ULL)

inline uintptr_t getRealOffset(uintptr_t offset) {
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)) + offset;
}

// ============================================================================
// [3. VARIABLES GLOBALES DE ESTADO]
// ============================================================================

bool g_SGLock_Active = false;

// ============================================================================
// [4. INTERFAZ GRÁFICA NATIVA (UI Master Switch)]
// ============================================================================

@interface SGLockButton : UIButton
@end

@implementation SGLockButton

- (void)toggleState {
    g_SGLock_Active = !g_SGLock_Active;
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
                                       initWithStyle:UIImpactFeedbackStyleMedium];
    [gen prepare];
    [gen impactOccurred];
    self.backgroundColor = g_SGLock_Active ? [UIColor greenColor] : [UIColor redColor];
    printf("[Tweak] SGLock is now %s\n", g_SGLock_Active ? "ENABLED" : "DISABLED");
}

- (void)dragged:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:self.superview];
        self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
        [pan setTranslation:CGPointZero inView:self.superview];
    }
}
@end

void InjectMasterSwitchUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *mainWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (w.isKeyWindow) { mainWindow = w; break; }
        if (!mainWindow) return;

        SGLockButton *btn = [SGLockButton buttonWithType:UIButtonTypeCustom];
        btn.frame              = CGRectMake(20, 100, 40, 40);
        btn.layer.cornerRadius = 20;
        btn.backgroundColor    = [UIColor redColor];
        btn.layer.borderWidth  = 2;
        btn.layer.borderColor  = [UIColor whiteColor].CGColor;
        btn.clipsToBounds      = YES;
        btn.alpha              = 0.85f;

        [btn addTarget:btn action:@selector(toggleState) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                        initWithTarget:btn action:@selector(dragged:)];
        [btn addGestureRecognizer:pan];
        [mainWindow addSubview:btn];
    });
}

// ============================================================================
// [5. FIRMAS DE FUNCIONES NATIVAS]
// ============================================================================

int    (*GetWeaponID)(void*);
uintptr_t (*PickTarget)(void*, void*, double);
FVector   (*K2_GetActorLocation)(uintptr_t);
void   (*AddControllerYawInput)(void*, float);
void   (*AddControllerPitchInput)(void*, float);

// ============================================================================
// [6. SYMBOL REBINDING (PAC-Safe — __DATA,__la_symbol_ptr)]
// ============================================================================

// Nombre mangled de UObject::ProcessEvent(UFunction*, void*)
static const char* kProcessEventSymbol = "_ZN7UObject12ProcessEventEP9UFunctionPv";

void (*orig_ProcessEvent)(void* _this, void* function, void* parms) = nullptr;

/**
 * @brief Itera sobre los segmentos __DATA del binario en búsqueda de la tabla
 *        de punteros de símbolos lazy (__la_symbol_ptr) o no-lazy (__nl_symbol_ptr)
 *        y reemplaza el puntero de 'symbolName' con 'newFunc'.
 *        Opera sobre memoria writable por defecto → No necesita mprotect → PAC-Safe.
 */
bool RebindSymbol(const char* symbolName, void* newFunc, void** origFunc) {
    const mach_header* mh = _dyld_get_image_header(0);
    if (!mh) return false;

    intptr_t slide = _dyld_get_image_vmaddr_slide(0);

    // Obtener el encabezado (64-bit)
    const mach_header_64* mh64 = reinterpret_cast<const mach_header_64*>(mh);
    const load_command*   lc   = reinterpret_cast<const load_command*>(mh64 + 1);

    // Rastrear tablas necesarias
    const symtab_command*    symtab    = nullptr;
    const dysymtab_command*  dysymtab  = nullptr;
    const segment_command_64* dataSegment = nullptr;

    for (uint32_t i = 0; i < mh64->ncmds; i++, lc = reinterpret_cast<const load_command*>(
            reinterpret_cast<const uint8_t*>(lc) + lc->cmdsize)) {
        if (lc->cmd == LC_SYMTAB)
            symtab = reinterpret_cast<const symtab_command*>(lc);
        else if (lc->cmd == LC_DYSYMTAB)
            dysymtab = reinterpret_cast<const dysymtab_command*>(lc);
        else if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, "__DATA", 6) == 0 ||
                strncmp(seg->segname, "__DATA_CONST", 12) == 0)
                dataSegment = seg;
        }
    }

    if (!symtab || !dysymtab || !dataSegment) return false;

    // Puntero base a la tabla de strings y nlist
    const char*          strtab = reinterpret_cast<const char*>(
                                    slide + symtab->stroff);
    const nlist_64*      nl     = reinterpret_cast<const nlist_64*>(
                                    slide + symtab->symoff);
    const uint32_t*      indirectSyms = reinterpret_cast<const uint32_t*>(
                                    slide + dysymtab->indirectsymoff);

    // Iterar secciones de __DATA buscando __la_symbol_ptr y __nl_symbol_ptr
    const section_64* sect = reinterpret_cast<const section_64*>(dataSegment + 1);
    for (uint32_t s = 0; s < dataSegment->nsects; s++, sect++) {
        uint8_t type = sect->flags & SECTION_TYPE;
        if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS)
            continue;

        uint32_t numPtrs = static_cast<uint32_t>(sect->size / sizeof(uintptr_t));
        uintptr_t* ptrTable = reinterpret_cast<uintptr_t*>(slide + sect->addr);

        for (uint32_t idx = 0; idx < numPtrs; idx++) {
            uint32_t symIdx = indirectSyms[sect->reserved1 + idx];
            if (symIdx & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
            if (symIdx >= symtab->nsyms) continue;

            const char* name = strtab + nl[symIdx].n_un.n_strx;
            if (strcmp(name, symbolName) != 0) continue;

            // Encontrado — reemplazar el puntero
            if (origFunc) *origFunc = reinterpret_cast<void*>(ptrTable[idx]);
            ptrTable[idx] = reinterpret_cast<uintptr_t>(newFunc);

            printf("[Tweak] Simbolo ProcessEvent re-enlazado correctamente (PAC-Safe).\n");
            return true;
        }
    }

    printf("[Tweak] Simbolo '%s' no encontrado en __DATA.\n", symbolName);
    return false;
}

// ============================================================================
// [7. PROCESSEVENT HOOK — NÚCLEO DEL AIMLOCK PERSISTENTE]
// ============================================================================

void hooked_ProcessEvent(void* _this, void* function, void* parms) {
    // 1. Master Switch — Coste cero si está apagado
    if (!g_SGLock_Active) {
        if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms);
        return;
    }

    // 2. Seguridad Anti-Crash
    if (!_this || !function) {
        if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms);
        return;
    }

    // 3. Resolución del evento ReceiveDrawHUD
    char* targetStr = reinterpret_cast<char*>(getRealOffset(ADDRESS_STRING_DRAW_HUD));
    bool isDrawHUD = IS_VALID_PTR(targetStr) && (memcmp(function, targetStr, 34) == 0);

    if (isDrawHUD) {
        uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
        if (IS_VALID_PTR(localPlayerBase)) {
            uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);

            if (IS_VALID_PTR(localPlayer)) {
                // _this en este contexto es el PlayerController
                uintptr_t playerController = reinterpret_cast<uintptr_t>(_this);

                // 4. Filtro de Arma
                int weaponID = GetWeaponID(reinterpret_cast<void*>(localPlayer));
                bool isShotgun = (((weaponID - 0x19641) < 4) || (weaponID == 0x196a5));

                if (isShotgun) {
                    // 5. Buscar Objetivo
                    uint8_t p1[16] = {0}, p2[16] = {0};
                    uintptr_t enemy = PickTarget(p1, p2, 0.0);

                    if (IS_VALID_PTR(enemy)) {
                        int healthState = *reinterpret_cast<int*>(enemy + OFFSET_HEALTH_STATE);
                        if (healthState != STATE_KNOCKED) {

                            // 6. Cálculo de dirección
                            FVector localPos = K2_GetActorLocation(localPlayer);
                            FVector enemyPos = K2_GetActorLocation(enemy);
                            FRotator target  = VectorToRotator(enemyPos - localPos);

                            FRotator current = *reinterpret_cast<FRotator*>(
                                                  playerController + OFFSET_CONTROL_ROTATION);

                            float dYaw   = NormalizeAxis(target.Yaw   - current.Yaw);
                            float dPitch = NormalizeAxis(target.Pitch - current.Pitch);

                            // 7. Input nativo suavizado
                            constexpr float smoothing = 0.5f;
                            if (AddControllerYawInput && AddControllerPitchInput) {
                                AddControllerYawInput(reinterpret_cast<void*>(playerController),
                                                      dYaw * smoothing);
                                AddControllerPitchInput(reinterpret_cast<void*>(playerController),
                                                        dPitch * smoothing);
                            }
                        }
                    }
                }
            }
        }
    }

    if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms);
}

// ============================================================================
// [8. PROTOCOLO DE ESTABILIDAD JAILED (QUAD-LOCK + SYMBOL REBINDING)]
// ============================================================================

void BackgroundInjectionThread() {
    printf("[LOG] Base Address: 0x%lX\n", reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)));

    // --- FASE 1: Delay inicial 10s → Inyección de UI ---
    std::this_thread::sleep_for(std::chrono::seconds(10));

    InjectMasterSwitchUI();
    printf("[LOG] UI inyectada. Esperando 5s para el hook...\n");

    // --- FASE 2: Delay adicional 5s → Symbol Rebinding ---
    std::this_thread::sleep_for(std::chrono::seconds(5));

    // Resolver funciones nativas del binario
    GetWeaponID        = reinterpret_cast<int (*)(void*)>(getRealOffset(OFFSET_GET_WEAPON_ID));
    PickTarget         = reinterpret_cast<uintptr_t (*)(void*, void*, double)>(getRealOffset(OFFSET_PICK_TARGET));
    K2_GetActorLocation= reinterpret_cast<FVector (*)(uintptr_t)>(getRealOffset(OFFSET_K2_GET_ACTOR_LOC));
    AddControllerYawInput   = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_YAW_INPUT));
    AddControllerPitchInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_PITCH_INPUT));

    // Aplicar Symbol Rebinding sobre __DATA (PAC-Safe, no requiere mprotect)
    bool ok = RebindSymbol(kProcessEventSymbol,
                           reinterpret_cast<void*>(hooked_ProcessEvent),
                           reinterpret_cast<void**>(&orig_ProcessEvent));

    if (!ok) {
        printf("[LOG] Rebinding fallido. El simbolo no existe en la tabla de importaciones.\n");
        printf("[LOG] Verifica que el juego enlaza ProcessEvent dinamicamente.\n");
    }
}

__attribute__((constructor))
static void init_tweak() {
    if (!_dyld_get_image_header(0)) return;
    std::thread(BackgroundInjectionThread).detach();
}
