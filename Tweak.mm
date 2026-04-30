#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>

// Dependencia de hooking (Dobby). Asegúrate de tener Dobby.h en tu entorno Theos ($THEOS/include).
#include <dobby.h>

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
        return orig_OnPelletsOnShotChanged(_this); // Retornar ejecución normal si no es escopeta
    }

    // 4. Obtener objetivo por FOV (p1 y p2 estructuras pasadas por referencia)
    uint8_t p1[16] = {0};
    uint8_t p2[16] = {0};
    uintptr_t closestEnemy = GetTargetForAimBotByFOV(p1, p2, 0.0);

    if (!closestEnemy) {
        return orig_OnPelletsOnShotChanged(_this); // Nadie en el FOV
    }

    // 5. Refinamiento del Filtro de Salud (Ignorar Noqueados)
    if (ignore_knocked) {
        int healthState = *reinterpret_cast<int*>(closestEnemy + OFFSET_HEALTH_STATE);
        if (healthState == STATE_KNOCKED) {
            printf("[SGLOCK] Objetivo descartado (Estado Noqueado detectado en %p)\n", (void*)closestEnemy);
            return orig_OnPelletsOnShotChanged(_this);
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

        // Aplicar esa rotación al PlayerController en el offset 0x548
        *reinterpret_cast<FRotator*>(localPlayer + 0x548) = targetRotation;
        
        printf("[SGLOCK] Aimlock aplicado al objetivo %p con éxito.\n", (void*)closestEnemy);
    }

    // 7. Llamar a la función original
    orig_OnPelletsOnShotChanged(_this);
}

// ============================================================================
// [6. INICIALIZACIÓN (CONSTRUCTOR)]
// ============================================================================

/**
 * @brief Constructor de la librería. Se ejecuta automáticamente al cargar el dylib.
 */
__attribute__((constructor))
static void init_tweak() {
    // Verificación básica para asegurar que el binario principal esté cargado
    if (!_dyld_get_image_header(0)) {
        return;
    }

    // Inicialización de las funciones externas extraídas de Ghidra sumando el ASLR
    GetWeaponID = reinterpret_cast<int (*)(void*)>(getRealOffset(0x4b2a30));
    GetTargetForAimBotByFOV = reinterpret_cast<uintptr_t (*)(void*, void*, double)>(getRealOffset(0x91e8));
    Conv_VectorToRotator = reinterpret_cast<FRotator (*)(FVector)>(getRealOffset(0xcf570));
    K2_GetActorLocation = reinterpret_cast<FVector (*)(uintptr_t)>(getRealOffset(0x1b844c));

    // Calcular dirección real del hook con el bypass de ASLR
    uintptr_t onPelletsAddr = getRealOffset(HOOK_ON_PELLETS);

    if (onPelletsAddr) {
        // Implementar el hook con Dobby (DobbyHook)
        // Firma: (void*)Dirección_Real, (void*)Dirección_Hook, (void**)&Función_Original
        DobbyHook(reinterpret_cast<void*>(onPelletsAddr), 
                  reinterpret_cast<void*>(hooked_OnPelletsOnShotChanged), 
                  reinterpret_cast<void**>(&orig_OnPelletsOnShotChanged));
        
        printf("[SGLOCK] Inicializado correctamente. Hook activo en: 0x%lX\n", onPelletsAddr);
    }
}
