#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>
#include <thread>
#include <chrono>
#include <sys/mman.h>
#include <unistd.h>
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
// [2. OFFSETS ACTUALIZADOS (v1.5.0 - Persistent ProcessEvent)]
// ============================================================================

constexpr uintptr_t OFFSET_LOCAL_PLAYER       = 0x951788; // Nuevo offset base del LocalPlayer
constexpr uintptr_t OFFSET_WEAPON_ID_FUNC     = 0x4c546c; // Nuevo offset GetWeaponID
constexpr uintptr_t OFFSET_TARGET_SELECTOR    = 0x91e8;
constexpr uintptr_t OFFSET_ACTOR_LOCATION     = 0x1b844c;
constexpr uintptr_t OFFSET_VECTOR_TO_ROTATOR  = 0xcf570;

// Offsets dependientes del volcado (A modificar con Ghidra/IDA):
constexpr uintptr_t OFFSET_PLAYER_CONTROLLER  = 0x30;     // Offset de PlayerController dentro de LocalPlayer
constexpr uintptr_t OFFSET_CONTROL_ROTATION   = 0x2e8;    // Offset de ControlRotation en PlayerController
constexpr uintptr_t OFFSET_HUD                = 0x2B0;    // Offset de MyHUD dentro de PlayerController
constexpr uintptr_t OFFSET_ADD_YAW_INPUT      = 0x000000; // TODO: Reemplazar con el offset real de AddControllerYawInput
constexpr uintptr_t OFFSET_ADD_PITCH_INPUT    = 0x000000; // TODO: Reemplazar con el offset real de AddControllerPitchInput

constexpr uintptr_t OFFSET_HEALTH_STATE       = 0x67c;
constexpr int       STATE_KNOCKED             = 0x92f92;

bool sg_lock_enabled = true; // Activado por defecto para pruebas
bool ignore_knocked  = true;

extern "C" __attribute__((visibility("default"))) void set_sglock_enabled(bool state) { sg_lock_enabled = state; }
extern "C" __attribute__((visibility("default"))) bool get_sglock_enabled() { return sg_lock_enabled; }

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

void (*orig_ProcessEvent)(void* _this, void* function, void* parms);

/**
 * @brief Helper ficticio para obtener el nombre de una UFunction.
 * Requiere implementar FNamePool en la versión final.
 */
std::string GetUFunctionName(void* function) {
    // TODO: Implementar la lectura real del nombre de la función desde FNamePool
    // Por ahora, asumiremos que todos los eventos que entran son DrawHUD ya que hookeamos el HUD.
    return "Function Engine.HUD.ReceiveDrawHUD";
}

/**
 * @brief Normaliza el ángulo Delta para que esté siempre entre -180 y 180.
 * Es crucial para que AddControllerInput no cause rotaciones erráticas o 360s en pantalla.
 */
float NormalizeAxis(float angle) {
    while (angle > 180.f) angle -= 360.f;
    while (angle < -180.f) angle += 360.f;
    return angle;
}

void hooked_ProcessEvent(void* _this, void* function, void* parms) {
    if (!sg_lock_enabled || !_this || !function) {
        if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms);
        return;
    }

    std::string funcName = GetUFunctionName(function);
    
    if (funcName == "Function Engine.HUD.ReceiveDrawHUD") {
        uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
        uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);
        
        if (localPlayer) {
            uintptr_t playerController = *reinterpret_cast<uintptr_t*>(localPlayer + OFFSET_PLAYER_CONTROLLER);
            if (playerController) {
                
                // Obtener WeaponID (Usualmente se extrae de la instancia del arma en el Pawn, 
                // pero bajo requerimiento técnico lo pasaremos usando el puntero local).
                int currentWeaponID = GetWeaponID(reinterpret_cast<void*>(localPlayer));
                
                // Filtro Exacto de Escopeta
                if (((currentWeaponID - 0x19641) < 4) || (currentWeaponID == 0x196a5)) {
                    
                    uint8_t p1[16] = {0};
                    uint8_t p2[16] = {0};
                    uintptr_t closestEnemy = GetTargetForAimBotByFOV(p1, p2, 0.0);

                    if (closestEnemy) {
                        int healthState = *reinterpret_cast<int*>(closestEnemy + OFFSET_HEALTH_STATE);
                        if (healthState != STATE_KNOCKED) {
                            
                            FVector localPos = K2_GetActorLocation(localPlayer);
                            FVector enemyPos = K2_GetActorLocation(closestEnemy);
                            FVector VectorDir = enemyPos - localPos;
                            
                            FRotator targetRotation = Conv_VectorToRotator(VectorDir);
                            FRotator currentRotation = *reinterpret_cast<FRotator*>(playerController + OFFSET_CONTROL_ROTATION);
                            
                            // Calcular Deltas normalizados
                            float deltaYaw = NormalizeAxis(targetRotation.Yaw - currentRotation.Yaw);
                            float deltaPitch = NormalizeAxis(targetRotation.Pitch - currentRotation.Pitch);
                            
                            // Suavizado dinámico (Smooth factor) - 0.5f significa que girará a la mitad de la velocidad por frame
                            float smoothing = 0.5f; 
                            
                            if (OFFSET_ADD_YAW_INPUT != 0x000000 && AddControllerYawInput && AddControllerPitchInput) {
                                AddControllerYawInput(reinterpret_cast<void*>(playerController), deltaYaw * smoothing);
                                AddControllerPitchInput(reinterpret_cast<void*>(playerController), deltaPitch * smoothing);
                            } else {
                                // Fallback: Si no has insertado los offsets de AddInput, escribimos directo.
                                FRotator smoothRotation = currentRotation;
                                smoothRotation.Yaw += (deltaYaw * smoothing);
                                smoothRotation.Pitch += (deltaPitch * smoothing);
                                *reinterpret_cast<FRotator*>(playerController + OFFSET_CONTROL_ROTATION) = smoothRotation;
                            }
                        }
                    }
                }
            }
        }
    }

    if (orig_ProcessEvent) {
        orig_ProcessEvent(_this, function, parms);
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
    
    if (OFFSET_ADD_YAW_INPUT != 0x000000) {
        AddControllerYawInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_YAW_INPUT));
        AddControllerPitchInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_PITCH_INPUT));
    }

    bool hookApplied = false;

    while (!hookApplied) {
        std::this_thread::sleep_for(std::chrono::seconds(2));

        uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
        uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);
        
        if (localPlayer) {
            printf("[LOG] LocalPlayer instanciado en memoria.\n");
            
            uintptr_t playerController = *reinterpret_cast<uintptr_t*>(localPlayer + OFFSET_PLAYER_CONTROLLER);
            if (playerController) {
                uintptr_t hudInstance = *reinterpret_cast<uintptr_t*>(playerController + OFFSET_HUD);
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
