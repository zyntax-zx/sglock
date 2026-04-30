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
// [2. OFFSETS NATIVOS FINALIZADOS (Direcciones Base 0)]
// ============================================================================

constexpr uintptr_t OFFSET_LOCAL_PLAYER       = 0x951788;
constexpr uintptr_t OFFSET_WEAPON_ID_FUNC     = 0x4c546c;
constexpr uintptr_t OFFSET_TARGET_SELECTOR    = 0x91e8;
constexpr uintptr_t OFFSET_ACTOR_LOCATION     = 0x1b844c;
constexpr uintptr_t OFFSET_VECTOR_TO_ROTATOR  = 0xcf570;

// Input Nativo
constexpr uintptr_t OFFSET_ADD_YAW_INPUT      = 0x1e3294;
constexpr uintptr_t OFFSET_ADD_PITCH_INPUT    = 0x1e33dc;

// Memoria Dinámica
constexpr uintptr_t ADDRESS_SHOTGUN_TOGGLE    = 0x9516b2; // bool
constexpr uintptr_t ADDRESS_ROTATION_OFFSET   = 0x951658; // uint32_t
constexpr uintptr_t ADDRESS_STRING_DRAW_HUD   = 0x0090cb2a; // char*

// Constantes de Instancia y Motor
constexpr uintptr_t OFFSET_PROCESS_EVENT      = 0x260;    // VTable Offset en bytes
constexpr uintptr_t OFFSET_PLAYER_CONTROLLER  = 0x30;
constexpr uintptr_t OFFSET_HUD                = 0x2b0;    // Offset jerárquico del HUD
constexpr uintptr_t OFFSET_HEALTH_STATE       = 0x67c;
constexpr int       STATE_KNOCKED             = 0x92f92;

/**
 * @brief Manejo seguro de ASLR para Base 0 en iOS.
 * Dado que los offsets de Ghidra fueron exportados con Base 0, 
 * la suma directa con el mach_header es el método nativo exacto. 
 * Equivalente a: _dyld_get_image_vmaddr_slide(0) + 0x100000000 + offset
 */
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
void (*AddControllerYawInput)(void*, float);
void (*AddControllerPitchInput)(void*, float);

// ============================================================================
// [4. VTABLE HOOK ENGINE (JAILED SAFE)]
// ============================================================================

bool ApplyVTableHookByByteOffset(void* instance, size_t byteOffset, void* hookedFunc, void** origFuncOut) {
    if (!instance) return false;
    
    uintptr_t* vtable = *reinterpret_cast<uintptr_t**>(instance);
    if (!vtable) return false;

    // Convertir offset en bytes a índice del array (arquitectura 64-bit)
    int vtableIndex = byteOffset / sizeof(uintptr_t);

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
// [5. INTERCEPCIÓN DEL PROCESSEVENT (NÚCLEO DEL AIMLOCK PERSISTENTE)]
// ============================================================================

void (*orig_ProcessEvent)(void* _this, void* function, void* parms, void* hud);

float NormalizeAxis(float angle) {
    while (angle > 180.f) angle -= 360.f;
    while (angle < -180.f) angle += 360.f;
    return angle;
}

void hooked_ProcessEvent(void* _this, void* function, void* parms, void* hud) {
    // 1. Memoria Dinámica: Interruptor (Shotgun Toggle)
    // Validación contra punteros nulos para evadir EXC_BAD_ACCESS
    if (!_this || !function || !hud) {
        if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms, hud);
        return;
    }

    bool isAimlockEnabled = *reinterpret_cast<bool*>(getRealOffset(ADDRESS_SHOTGUN_TOGGLE));
    if (!isAimlockEnabled) {
        if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms, hud);
        return;
    }

    // 2. Resolución de Evento (HUD) - _memcmp dinámico nativo
    char* targetEventString = reinterpret_cast<char*>(getRealOffset(ADDRESS_STRING_DRAW_HUD));
    bool isDrawHUD = false;
    
    if (targetEventString) {
        if (memcmp(function, targetEventString, 34) == 0) {
            isDrawHUD = true;
        }
    }

    if (isDrawHUD) {
        // 3. Validación de Estructuras (PlayerController vía param_4)
        uintptr_t playerController = *reinterpret_cast<uintptr_t*>((uintptr_t)hud + OFFSET_PLAYER_CONTROLLER);
        if (playerController) {
            
            uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
            if (localPlayerBase) {
                uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);

                if (localPlayer) {
                    // 4. Obtener ID del Arma (WeaponID)
                    int currentWeaponID = GetWeaponID(reinterpret_cast<void*>(localPlayer));
                    
                    // 5. Filtro de Arma (Escopetas)
                    if (((currentWeaponID - 0x19641) < 4) || (currentWeaponID == 0x196a5)) {
                        
                        uint8_t p1[16] = {0};
                        uint8_t p2[16] = {0};
                        uintptr_t closestEnemy = GetTargetForAimBotByFOV(p1, p2, 0.0);

                        if (closestEnemy) {
                            // Filtro de Salud Prioritario (Noqueados)
                            int healthState = *reinterpret_cast<int*>(closestEnemy + OFFSET_HEALTH_STATE);
                            if (healthState != STATE_KNOCKED) {
                                
                                // 6. Cálculo Direccional Vectorial
                                FVector localPos = K2_GetActorLocation(localPlayer);
                                FVector enemyPos = K2_GetActorLocation(closestEnemy);
                                FVector VectorDir = enemyPos - localPos;
                                
                                FRotator targetRotation = Conv_VectorToRotator(VectorDir);
                                
                                // 7. Lectura del Offset de Rotación Dinámico
                                uint32_t dynamicRotOffset = *reinterpret_cast<uint32_t*>(getRealOffset(ADDRESS_ROTATION_OFFSET));
                                FRotator currentRotation = *reinterpret_cast<FRotator*>(playerController + dynamicRotOffset);
                                
                                // Cálculo de Delta Normalizado
                                float deltaYaw = NormalizeAxis(targetRotation.Yaw - currentRotation.Yaw);
                                float deltaPitch = NormalizeAxis(targetRotation.Pitch - currentRotation.Pitch);
                                
                                // 8. Sistema de Apuntado (Input Nativo Seguro)
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
    }

    // Retorno al flujo nativo
    if (orig_ProcessEvent) {
        orig_ProcessEvent(_this, function, parms, hud);
    }
}

// ============================================================================
// [6. INICIALIZACIÓN E INYECCIÓN]
// ============================================================================

void BackgroundInjectionThread() {
    printf("[LOG] Base Address encontrada: 0x%lX\n", reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)));
    
    // Asignación estricta de funciones externas
    GetWeaponID = reinterpret_cast<int (*)(void*)>(getRealOffset(OFFSET_WEAPON_ID_FUNC));
    GetTargetForAimBotByFOV = reinterpret_cast<uintptr_t (*)(void*, void*, double)>(getRealOffset(OFFSET_TARGET_SELECTOR));
    Conv_VectorToRotator = reinterpret_cast<FRotator (*)(FVector)>(getRealOffset(OFFSET_VECTOR_TO_ROTATOR));
    K2_GetActorLocation = reinterpret_cast<FVector (*)(uintptr_t)>(getRealOffset(OFFSET_ACTOR_LOCATION));
    
    AddControllerYawInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_YAW_INPUT));
    AddControllerPitchInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_PITCH_INPUT));

    bool hookApplied = false;

    // Bucle de inicialización asíncrono
    while (!hookApplied) {
        std::this_thread::sleep_for(std::chrono::seconds(2));

        uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
        if (!localPlayerBase) continue;
        
        uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);
        if (localPlayer) {
            printf("[LOG] LocalPlayer instanciado en memoria.\n");
            
            uintptr_t playerController = *reinterpret_cast<uintptr_t*>(localPlayer + OFFSET_PLAYER_CONTROLLER); 
            if (playerController) {
                uintptr_t hudInstance = *reinterpret_cast<uintptr_t*>(playerController + OFFSET_HUD); 
                if (hudInstance) {
                    
                    // Inyección a través de VTable Byte Offset
                    hookApplied = ApplyVTableHookByByteOffset(reinterpret_cast<void*>(hudInstance), 
                                                              OFFSET_PROCESS_EVENT, 
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
