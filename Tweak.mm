#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>
#include <thread>
#include <chrono>
#include <sys/mman.h>
#include <unistd.h>

// ============================================================================
// [1. ESTRUCTURAS LIGERAS]
// ============================================================================

// Estructura ligera para vectores 3D sin depender de Unreal Engine SDK.
struct FVector {
    float X, Y, Z;
    
    FVector operator-(const FVector& Other) const {
        return { X - Other.X, Y - Other.Y, Z - Other.Z };
    }
};

// Estructura ligera para rotadores (ángulos de Euler).
struct FRotator {
    float Pitch, Yaw, Roll;
};

// ============================================================================
// [2. OFFSETS GLOBALES]
// ============================================================================

// Offsets crudos extraídos previamente mediante ingeniería inversa (Ghidra/IDA).
constexpr uintptr_t OFFSET_LOCAL_PLAYER      = 0xdb8;
constexpr uintptr_t OFFSET_PLAYER_CONTROLLER = 0x548;
constexpr uintptr_t OFFSET_HEALTH_STATE      = 0x67c;
constexpr int       STATE_KNOCKED            = 0x92f92;
constexpr uintptr_t HOOK_ON_PELLETS          = 0x3447f4;

// ============================================================================
// [3. VARIABLES DE CONFIGURACIÓN (TOGGLES)]
// ============================================================================

// Variables globales de estado.
bool sg_lock_enabled = false; // Inicia desactivado para que el usuario lo active manualmente.
bool ignore_knocked  = true;

// Exponemos las funciones a nivel C con visibilidad global para que cualquier 
// Mod Menu (ImGui, nativo) pueda importarlas y cambiar el estado en vivo.
extern "C" __attribute__((visibility("default"))) void set_sglock_enabled(bool state) {
    sg_lock_enabled = state;
}

extern "C" __attribute__((visibility("default"))) bool get_sglock_enabled() {
    return sg_lock_enabled;
}

// ============================================================================
// [4. FUNCIONES AUXILIARES & ASLR]
// ============================================================================

/**
 * @brief Obtiene la dirección de memoria real evadiendo el ASLR (Address Space Layout Randomization).
 * @param offset El offset estático extraído del binario desempaquetado.
 * @return Dirección real de memoria en tiempo de ejecución.
 */
inline uintptr_t getRealOffset(uintptr_t offset) {
    // _dyld_get_image_header(0) devuelve la dirección base en la que se ha cargado el ejecutable principal.
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)) + offset;
}

// ----------------------------------------------------------------------------
// Funciones Originales Extraídas de Ghidra (Punteros Globales)
// ----------------------------------------------------------------------------

// Offset 0x4b2a30. Firma: int GetWeaponID(void* weaponInstance);
int (*GetWeaponID)(void*);

// Offset 0x91e8. Firma: uintptr_t GetTargetForAimBotByFOV(void* p1, void* p2, double p3);
uintptr_t (*GetTargetForAimBotByFOV)(void*, void*, double);

// Offset 0xcf570. Firma: FRotator Conv_VectorToRotator(FVector vector);
FRotator (*Conv_VectorToRotator)(FVector);

// Offset 0x1b844c. Firma: FVector K2_GetActorLocation(uintptr_t actorInstance);
FVector (*K2_GetActorLocation)(uintptr_t);

// ============================================================================
// [5. FUNCIÓN DE HOOKING (EL NÚCLEO)]
// ============================================================================

// Puntero estático para almacenar la función original
void (*orig_OnPelletsOnShotChanged)(void* _this);

/**
 * @brief Función parcheada (Hook) de OnPelletsOnShotChanged usando convención ARM64.
 */
void hooked_OnPelletsOnShotChanged(void* _this) {
    // 1. Verificación de seguridad (Null Pointer) y toggle
    if (!sg_lock_enabled || !_this) {
        return orig_OnPelletsOnShotChanged(_this);
    }

    // 2. Obtener el ID del arma usando la función extraída
    int currentWeaponID = GetWeaponID(_this);
    
    // Log para verificar en consola (útil para CFLog/syslog en iOS)
    printf("[SGLOCK] Disparo detectado. GetWeaponID retornado: 0x%X\n", currentWeaponID);

    // 3. Filtrar: Lógica exacta de escopeta
    if (!(((currentWeaponID - 0x19641) < 4) || (currentWeaponID == 0x196a5))) {
        if (orig_OnPelletsOnShotChanged) orig_OnPelletsOnShotChanged(_this);
        return;
    }

    printf("[LOG] Lock activado para WeaponID: 0x%X\n", currentWeaponID);

    // 4. Obtener objetivo por FOV (p1 y p2 estructuras pasadas por referencia)
    uint8_t p1[16] = {0};
    uint8_t p2[16] = {0};
    uintptr_t closestEnemy = GetTargetForAimBotByFOV(p1, p2, 0.0);

    if (!closestEnemy) {
        if (orig_OnPelletsOnShotChanged) orig_OnPelletsOnShotChanged(_this);
        return;
    }

    // 5. Refinamiento del Filtro de Salud (Ignorar Noqueados)
    if (ignore_knocked) {
        int healthState = *reinterpret_cast<int*>(closestEnemy + OFFSET_HEALTH_STATE);
        if (healthState == STATE_KNOCKED) {
            if (orig_OnPelletsOnShotChanged) orig_OnPelletsOnShotChanged(_this);
            return;
        }
    }

    // 6. Ejecución del Aimlock (Matemática Final)
    uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(getRealOffset(OFFSET_LOCAL_PLAYER));
    if (localPlayer) {
        // Obtenemos posiciones usando la función nativa K2_GetActorLocation
        FVector localPos = K2_GetActorLocation(localPlayer);
        FVector enemyPos = K2_GetActorLocation(closestEnemy);

        // Calcular vector de dirección
        FVector VectorDir = enemyPos - localPos;

        // Pasar VectorDir a la función Conv_VectorToRotator
        FRotator targetRotation = Conv_VectorToRotator(VectorDir);

        // Aplicar esa rotación al PlayerController en el offset declarado
        *reinterpret_cast<FRotator*>(localPlayer + OFFSET_PLAYER_CONTROLLER) = targetRotation;
    }

    // 7. Llamar a la función original
    if (orig_OnPelletsOnShotChanged) {
        orig_OnPelletsOnShotChanged(_this);
    }
}

// ============================================================================
// [6. MOTOR DE HOOKING JAILED-SAFE (VTABLE SWAP)]
// ============================================================================

/**
 * @brief Implementa un VTable Swap escaneando la tabla virtual del objeto instanciado.
 * Evita modificar el segmento __TEXT, evadiendo EXC_BAD_ACCESS y detección de Anti-Cheat.
 */
bool ApplyVTableHook(void* instance, uintptr_t targetFuncAddr, void* hookedFunc, void** origFuncOut) {
    if (!instance) return false;

    // Obtener el puntero a la VTable (primeros 8 bytes del objeto en memoria)
    uintptr_t* vtable = *reinterpret_cast<uintptr_t**>(instance);
    if (!vtable) return false;

    // Escanear la VTable buscando la función objetivo (Límite de seguridad 500 índices)
    for (int i = 0; i < 500; i++) {
        if (vtable[i] == targetFuncAddr) {
            // Guardar el puntero original
            if (origFuncOut) {
                *origFuncOut = reinterpret_cast<void*>(vtable[i]);
            }

            // Cambiar protección de la página en __DATA_CONST para permitir escritura temporal
            size_t pageSize = sysconf(_SC_PAGESIZE);
            uintptr_t pageStart = reinterpret_cast<uintptr_t>(&vtable[i]) & ~(pageSize - 1);
            
            // mprotect puede fallar sin JIT en algunas versiones de iOS. Si falla, se recomienda el "Instance VTable Copy".
            if (mprotect(reinterpret_cast<void*>(pageStart), pageSize, PROT_READ | PROT_WRITE) == 0) {
                // Intercambio de puntero (Swap)
                vtable[i] = reinterpret_cast<uintptr_t>(hookedFunc);
                
                // Restaurar protección original (Solo lectura)
                mprotect(reinterpret_cast<void*>(pageStart), pageSize, PROT_READ);
                
                printf("[LOG] Intentando VTable Swap en WeaponComponent. (Exito en indice %d)\n", i);
                return true;
            } else {
                printf("[LOG] Falla en mprotect. El entorno Jailed prohíbe escritura en esta página.\n");
                return false;
            }
        }
    }
    printf("[LOG] Función original no encontrada en la VTable del objeto.\n");
    return false;
}

// ============================================================================
// [7. INICIALIZACIÓN (CONSTRUCTOR Y BACKGROUND THREAD)]
// ============================================================================

/**
 * @brief Obtiene el WeaponComponent desde el LocalPlayer.
 * (A IMPLEMENTAR: Reemplaza los offsets ficticios con los de tu juego).
 */
void* GetWeaponComponent(uintptr_t localPlayer) {
    // Ejemplo de jerarquía de Unreal Engine: LocalPlayer -> PlayerController -> Pawn -> WeaponComponent
    // TODO: Ajusta estos offsets según tu volcado de Ghidra.
    uintptr_t playerController = *reinterpret_cast<uintptr_t*>(localPlayer + OFFSET_PLAYER_CONTROLLER);
    if (playerController) {
        uintptr_t pawn = *reinterpret_cast<uintptr_t*>(playerController + 0x330); // Offset ficticio de Pawn
        if (pawn) {
            uintptr_t weaponComp = *reinterpret_cast<uintptr_t*>(pawn + 0x8A0); // Offset ficticio de WeaponComponent
            return reinterpret_cast<void*>(weaponComp);
        }
    }
    return nullptr;
}

/**
 * @brief Hilo de fondo que espera a que el entorno esté listo para aplicar el VTable Swap.
 */
void BackgroundInjectionThread() {
    printf("[LOG] Base Address encontrada: 0x%lX\n", reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)));
    
    // Inicialización de funciones externas (ASLR)
    GetWeaponID = reinterpret_cast<int (*)(void*)>(getRealOffset(0x4b2a30));
    GetTargetForAimBotByFOV = reinterpret_cast<uintptr_t (*)(void*, void*, double)>(getRealOffset(0x91e8));
    Conv_VectorToRotator = reinterpret_cast<FRotator (*)(FVector)>(getRealOffset(0xcf570));
    K2_GetActorLocation = reinterpret_cast<FVector (*)(uintptr_t)>(getRealOffset(0x1b844c));

    uintptr_t targetFuncAddr = getRealOffset(HOOK_ON_PELLETS);
    bool hookApplied = false;

    // Loop de espera activa hasta que el jugador aparezca en memoria
    while (!hookApplied) {
        std::this_thread::sleep_for(std::chrono::seconds(2));

        uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(getRealOffset(OFFSET_LOCAL_PLAYER));
        if (localPlayer) {
            printf("[LOG] LocalPlayer instanciado en memoria.\n");

            void* weaponComponent = GetWeaponComponent(localPlayer);
            if (weaponComponent) {
                // Aplicar el VTable Swap en el segmento __DATA
                hookApplied = ApplyVTableHook(weaponComponent, 
                                              targetFuncAddr, 
                                              reinterpret_cast<void*>(hooked_OnPelletsOnShotChanged), 
                                              reinterpret_cast<void**>(&orig_OnPelletsOnShotChanged));
            }
        }
    }
}

/**
 * @brief Constructor de la librería.
 */
__attribute__((constructor))
static void init_tweak() {
    if (!_dyld_get_image_header(0)) return;
    
    // Lanzar hilo en segundo plano para no congelar el arranque del juego
    std::thread(BackgroundInjectionThread).detach();
}
