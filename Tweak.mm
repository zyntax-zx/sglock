#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>
#include <thread>
#include <chrono>
#include <sys/mman.h>
#include <unistd.h>
#include <cstring>
#include <string>

// ============================================================================
// [1. ESTRUCTURAS LIGERAS Y MATEMÁTICAS]
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

// ============================================================================
// [2. OFFSETS ACTUALIZADOS (v2.1 - Persistent ProcessEvent & Dynamic Values)]
// ============================================================================

constexpr uintptr_t OFFSET_LOCAL_PLAYER       = 0x951788; // Dirección base del LocalPlayer
constexpr uintptr_t OFFSET_WEAPON_ID_FUNC     = 0x4c546c; // GetWeaponID
constexpr uintptr_t OFFSET_TARGET_SELECTOR    = 0x91e8;
constexpr uintptr_t OFFSET_ACTOR_LOCATION     = 0x1b844c;
constexpr uintptr_t OFFSET_VECTOR_TO_ROTATOR  = 0xcf570;

// Offsets de Movimiento de Cámara Nativo (Input):
constexpr uintptr_t OFFSET_ADD_YAW_INPUT      = 0x1e3294;
constexpr uintptr_t OFFSET_ADD_PITCH_INPUT    = 0x1e33dc;

// Direcciones de Memoria Dinámica:
constexpr uintptr_t ADDRESS_SHOTGUN_TOGGLE    = 0x9516b2; // bool
constexpr uintptr_t ADDRESS_ROTATION_OFFSET   = 0x951658; // uint32_t
constexpr uintptr_t ADDRESS_STRING_DRAW_HUD   = 0x0090cb2a; // char* (String pointer)

// Offsets Relativos (A modificar según tu jerarquía interna de ser necesario)
constexpr uintptr_t OFFSET_PLAYER_CONTROLLER  = 0x30; // Offset para obtener PlayerController
constexpr uintptr_t OFFSET_HEALTH_STATE       = 0x67c;
constexpr int       STATE_KNOCKED             = 0x92f92;

inline uintptr_t getRealOffset(uintptr_t offset) {
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)) + offset;
}

// ============================================================================
// [3. FIRMAS DE FUNCIONES NATIVAS]
// ============================================================================

int (*GetWeaponID)(void*);
uintptr_t (*GetTargetForAimBotByFOV)(void*, void*, double);
FVector (*K2_GetActorLocation)(uintptr_t);
FRotator (*Conv_VectorToRotator)(FVector);

// Firmas para la persistencia fluida (Smooth Aiming)
void (*AddControllerYawInput)(void*, float);
void (*AddControllerPitchInput)(void*, float);

// ============================================================================
// [4. VTABLE HOOK ENGINE (JAILED SAFE)]
// ============================================================================

bool ApplyVTableHookByIndex(void* instance, int vtableIndex, void* hookedFunc, void** origFuncOut) {
    if (!instance) return false;
    uintptr_t* vtable = *reinterpret_cast<uintptr_t**>(instance);
    if (!vtable) return false;

    if (origFuncOut) {
        *origFuncOut = reinterpret_cast<void*>(vtable[vtableIndex]);
    }

    size_t pageSize = sysconf(_SC_PAGESIZE);
    uintptr_t pageStart = reinterpret_cast<uintptr_t>(&vtable[vtableIndex]) & ~(pageSize - 1);
    
    if (mprotect(reinterpret_cast<void*>(pageStart), pageSize, PROT_READ | PROT_WRITE) == 0) {
        vtable[vtableIndex] = reinterpret_cast<uintptr_t>(hookedFunc);
        mprotect(reinterpret_cast<void*>(pageStart), pageSize, PROT_READ);
        return true;
    }
    return false;
}

// ============================================================================
// [5. INTERCEPCIÓN DEL PROCESSEVENT (NÚCLEO DEL AIMLOCK)]
// ============================================================================

// Firma actualizada con param_4 (hud) según requerimiento técnico.
void (*orig_ProcessEvent)(void* _this, void* function, void* parms, void* hud);

float NormalizeAxis(float angle) {
    while (angle > 180.f) angle -= 360.f;
    while (angle < -180.f) angle += 360.f;
    return angle;
}

void hooked_ProcessEvent(void* _this, void* function, void* parms, void* hud) {
    // 1. Memoria Dinámica: Interruptor (Shotgun Toggle)
    bool isAimlockEnabled = *reinterpret_cast<bool*>(getRealOffset(ADDRESS_SHOTGUN_TOGGLE));
    
    if (!isAimlockEnabled || !_this || !function || !hud) {
        if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms, hud);
        return;
    }

    // 2. Resolución de Strings (HUD) - _memcmp dinámico
    char* targetEventString = reinterpret_cast<char*>(getRealOffset(ADDRESS_STRING_DRAW_HUD));
    bool isDrawHUD = false;
    
    // Asumiendo que el dylib base del autor original pasa el string evaluable en 'function' 
    // o un puntero directo que puede compararse con _memcmp para evitar ofuscaciones de FName.
    // "Function Engine.HUD.ReceiveDrawHUD" tiene 34 caracteres de longitud.
    if (memcmp(function, targetEventString, 34) == 0) {
        isDrawHUD = true;
    }

    if (isDrawHUD) {
        // 3. Validación de Estructuras (Obtención de PlayerController desde param_4 "hud")
        uintptr_t playerController = *reinterpret_cast<uintptr_t*>((uintptr_t)hud + OFFSET_PLAYER_CONTROLLER);
        
        if (playerController) {
            uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
            uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);

            if (localPlayer) {
                // Obtener ID del Arma (WeaponID del jugador local)
                int currentWeaponID = GetWeaponID(reinterpret_cast<void*>(localPlayer));
                
                // Filtro Exacto de Escopeta
                if (((currentWeaponID - 0x19641) < 4) || (currentWeaponID == 0x196a5)) {
                    
                    uint8_t p1[16] = {0};
                    uint8_t p2[16] = {0};
                    uintptr_t closestEnemy = GetTargetForAimBotByFOV(p1, p2, 0.0);

                    if (closestEnemy) {
                        // Filtro de Noqueados (Priority)
                        int healthState = *reinterpret_cast<int*>(closestEnemy + OFFSET_HEALTH_STATE);
                        if (healthState != STATE_KNOCKED) {
                            
                            FVector localPos = K2_GetActorLocation(localPlayer);
                            FVector enemyPos = K2_GetActorLocation(closestEnemy);
                            FVector VectorDir = enemyPos - localPos;
                            
                            FRotator targetRotation = Conv_VectorToRotator(VectorDir);
                            
                            // 4. Dynamic Rotation Offset
                            uint32_t dynamicRotOffset = *reinterpret_cast<uint32_t*>(getRealOffset(ADDRESS_ROTATION_OFFSET));
                            FRotator currentRotation = *reinterpret_cast<FRotator*>(playerController + dynamicRotOffset);
                            
                            float deltaYaw = NormalizeAxis(targetRotation.Yaw - currentRotation.Yaw);
                            float deltaPitch = NormalizeAxis(targetRotation.Pitch - currentRotation.Pitch);
                            
                            // 5. Apuntado Suave (Smooth Persistence) mediante Input Nativo
                            float smoothing = 0.5f; 
                            
                            if (AddControllerYawInput && AddControllerPitchInput) {
                                AddControllerYawInput(reinterpret_cast<void*>(playerController), deltaYaw * smoothing);
                                AddControllerPitchInput(reinterpret_cast<void*>(playerController), deltaPitch * smoothing);
                            }
                        }
                    }
                }
            }
        }
    }

    if (orig_ProcessEvent) {
        orig_ProcessEvent(_this, function, parms, hud);
    }
}

// ============================================================================
// [6. INICIALIZACIÓN E INYECCIÓN]
// ============================================================================

void BackgroundInjectionThread() {
    printf("[LOG] Base Address encontrada: 0x%lX\n", reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)));
    
    GetWeaponID = reinterpret_cast<int (*)(void*)>(getRealOffset(OFFSET_WEAPON_ID_FUNC));
    GetTargetForAimBotByFOV = reinterpret_cast<uintptr_t (*)(void*, void*, double)>(getRealOffset(OFFSET_TARGET_SELECTOR));
    Conv_VectorToRotator = reinterpret_cast<FRotator (*)(FVector)>(getRealOffset(OFFSET_VECTOR_TO_ROTATOR));
    K2_GetActorLocation = reinterpret_cast<FVector (*)(uintptr_t)>(getRealOffset(OFFSET_ACTOR_LOCATION));
    
    AddControllerYawInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_YAW_INPUT));
    AddControllerPitchInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_PITCH_INPUT));

    bool hookApplied = false;

    while (!hookApplied) {
        std::this_thread::sleep_for(std::chrono::seconds(2));

        uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
        if (!localPlayerBase) continue;
        
        uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);
        if (localPlayer) {
            printf("[LOG] LocalPlayer instanciado en memoria.\n");
            
            // Para el HUD, solemos buscarlo a través de PlayerController
            uintptr_t playerController = *reinterpret_cast<uintptr_t*>(localPlayer + OFFSET_PLAYER_CONTROLLER); 
            if (playerController) {
                // TODO: Usar el offset real para acceder a MyHUD desde el PlayerController (Ej. 0x2b0)
                uintptr_t hudInstance = *reinterpret_cast<uintptr_t*>(playerController + 0x2b0); 
                if (hudInstance) {
                    // El Índice VTable de ProcessEvent en UObject suele ser 66 o 67.
                    int processEventVTableIndex = 66; 
                    hookApplied = ApplyVTableHookByIndex(reinterpret_cast<void*>(hudInstance), 
                                                         processEventVTableIndex, 
                                                         reinterpret_cast<void*>(hooked_ProcessEvent), 
                                                         reinterpret_cast<void**>(&orig_ProcessEvent));
                                                  
                    if (hookApplied) {
                        printf("[LOG] Intentando VTable Swap en ProcessEvent (HUD). Exito!\n");
                    }
                }
            }
        }
    }
}

__attribute__((constructor))
static void init_tweak() {
    if (!_dyld_get_image_header(0)) return;
    std::thread(BackgroundInjectionThread).detach();
}
