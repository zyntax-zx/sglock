#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>
#include <thread>
#include <chrono>
#include <sys/mman.h>
#include <unistd.h>
#include <cstring>

// ============================================================================
// [1. ESTRUCTURAS Y MATEMÁTICAS (Custom Engine)]
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

// Conversión Matemática Vector a Rotador (Elimina dependencia de offset externo)
FRotator VectorToRotator(FVector dir) {
    FRotator rot;
    rot.Yaw = atan2(dir.Y, dir.X) * (180.0f / M_PI);
    rot.Pitch = atan2(dir.Z, sqrt(dir.X * dir.X + dir.Y * dir.Y)) * (180.0f / M_PI);
    rot.Roll = 0.0f;
    return rot;
}

float NormalizeAxis(float angle) {
    while (angle > 180.f) angle -= 360.f;
    while (angle < -180.f) angle += 360.f;
    return angle;
}

// ============================================================================
// [2. TABLA DE LA VERDAD (Offsets v2.0 Estrictos)]
// ============================================================================

constexpr uintptr_t OFFSET_LOCAL_PLAYER       = 0x951788;
constexpr uintptr_t OFFSET_PROCESS_EVENT      = 0x260;
constexpr uintptr_t OFFSET_GET_WEAPON_ID      = 0x4c546c;
constexpr uintptr_t OFFSET_K2_GET_ACTOR_LOC   = 0x1b844c;
constexpr uintptr_t OFFSET_ADD_YAW_INPUT      = 0x1e3294;
constexpr uintptr_t OFFSET_ADD_PITCH_INPUT    = 0x1e33dc;
constexpr uintptr_t OFFSET_PICK_TARGET        = 0x0b27f0;
constexpr uintptr_t ADDRESS_STRING_DRAW_HUD   = 0x90cb2a;
constexpr uintptr_t OFFSET_HEALTH_STATE       = 0x67c;
constexpr uintptr_t OFFSET_PLAYER_CONTROLLER  = 0x548;

constexpr int       STATE_KNOCKED             = 0x92f92;

// Offset estándar de Unreal Engine (Usado para calcular el Delta)
constexpr uintptr_t OFFSET_CONTROL_ROTATION   = 0x2e8; 

#define IS_VALID_PTR(p) ((uintptr_t)(p) > 0x100000000)

inline uintptr_t getRealOffset(uintptr_t offset) {
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)) + offset;
}

// ============================================================================
// [3. VARIABLES GLOBALES DE ESTADO Y CONTROL]
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
    
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [generator prepare];
    [generator impactOccurred];
    
    if (g_SGLock_Active) {
        self.backgroundColor = [UIColor greenColor];
    } else {
        self.backgroundColor = [UIColor redColor];
    }
    
    printf("[Tweak] SGLock is now %s\n", g_SGLock_Active ? "ENABLED" : "DISABLED");
}

- (void)dragged:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [pan translationInView:self.superview];
        self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        [pan setTranslation:CGPointZero inView:self.superview];
    }
}
@end

void InjectMasterSwitchUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *mainWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) {
                mainWindow = w;
                break;
            }
        }
        
        if (!mainWindow) return;
        
        SGLockButton *btn = [SGLockButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(20, 100, 40, 40); 
        btn.layer.cornerRadius = 20; 
        btn.backgroundColor = [UIColor redColor]; 
        btn.layer.borderWidth = 2;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        btn.clipsToBounds = YES;
        btn.alpha = 0.85; 
        
        [btn addTarget:btn action:@selector(toggleState) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(dragged:)];
        [btn addGestureRecognizer:pan];
        
        [mainWindow addSubview:btn];
    });
}

// ============================================================================
// [5. FIRMAS DE FUNCIONES NATIVAS]
// ============================================================================

int (*GetWeaponID)(void*);
uintptr_t (*PickTarget)(void*, void*, double);
FVector (*K2_GetActorLocation)(uintptr_t);
void (*AddControllerYawInput)(void*, float);
void (*AddControllerPitchInput)(void*, float);

// ============================================================================
// [6. SHADOW VTABLE HOOK (JAILED SAFE - INSTANCE SWAP)]
// ============================================================================

#ifdef __arm64e__
#define STRIP_PAC(x) ((uintptr_t)(x) & 0x0000000fffffffffULL)
#else
#define STRIP_PAC(x) ((uintptr_t)(x))
#endif

bool ApplyShadowVTableHook(void* instance, size_t byteOffset, void* hookedFunc, void** origFuncOut) {
    if (!instance) return false;
    
    // El puntero a la VTable original reside en los primeros 8 bytes de la instancia
    uintptr_t* originalVTable = *reinterpret_cast<uintptr_t**>(instance);
    if (!originalVTable) return false;

    // Clonación de VTable en el Heap (Memoria propia = 0 sospechas del kernel)
    int vtableLength = 350; // Tamaño generoso (El offset 0x260 es índice 76)
    uintptr_t* shadowVTable = new uintptr_t[vtableLength];
    memcpy(shadowVTable, originalVTable, vtableLength * sizeof(uintptr_t));

    int vtableIndex = byteOffset / sizeof(uintptr_t);

    if (origFuncOut) {
        // Almacenamos el puntero original eliminando la firma PAC si estamos en arm64e
        *origFuncOut = reinterpret_cast<void*>(STRIP_PAC(originalVTable[vtableIndex]));
    }

    // Reemplazamos la función deseada en nuestra copia plana
    shadowVTable[vtableIndex] = reinterpret_cast<uintptr_t>(hookedFunc);
    
    // Instance Swap: Apuntamos el objeto a nuestra nueva VTable modificada
    *reinterpret_cast<uintptr_t**>(instance) = shadowVTable;

    return true;
}

// ============================================================================
// [7. INTERCEPCIÓN DEL PROCESSEVENT (NÚCLEO DEL AIMLOCK PERSISTENTE)]
// ============================================================================

void (*orig_ProcessEvent)(void* _this, void* function, void* parms);

void hooked_ProcessEvent(void* _this, void* function, void* parms) {
    // 1. Master Switch 
    if (!g_SGLock_Active) {
        if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms);
        return;
    }

    // 2. Seguridad Anti-Crash
    if (!_this || !function) {
        if (orig_ProcessEvent) orig_ProcessEvent(_this, function, parms);
        return;
    }

    // 3. Resolución de Evento - _memcmp nativo
    char* targetEventString = reinterpret_cast<char*>(getRealOffset(ADDRESS_STRING_DRAW_HUD));
    bool isDrawHUD = false;
    
    if (IS_VALID_PTR(targetEventString)) {
        if (memcmp(function, targetEventString, 34) == 0) {
            isDrawHUD = true;
        }
    }

    if (isDrawHUD) {
        // Al hookear el PlayerController, '_this' es la instancia del PlayerController
        uintptr_t playerController = reinterpret_cast<uintptr_t>(_this);
        if (IS_VALID_PTR(playerController)) {
            
            uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
            if (IS_VALID_PTR(localPlayerBase)) {
                uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);

                if (IS_VALID_PTR(localPlayer)) {
                    
                    // 4. Identificar Arma
                    int weaponID = GetWeaponID(reinterpret_cast<void*>(localPlayer));
                    
                    // Filtro Definitivo
                    bool isShotgun = (((weaponID - 0x19641) < 4) || (weaponID == 0x196a5));
                    
                    if (isShotgun) {
                        
                        // 5. Buscar Objetivo (VineHookTargetPicker)
                        uint8_t p1[16] = {0};
                        uint8_t p2[16] = {0};
                        uintptr_t closestEnemy = PickTarget(p1, p2, 0.0);

                        if (IS_VALID_PTR(closestEnemy)) {
                            int healthState = *reinterpret_cast<int*>(closestEnemy + OFFSET_HEALTH_STATE);
                            if (healthState != STATE_KNOCKED) {
                                
                                // 6. Cálculos de Rotación Locales
                                FVector localPos = K2_GetActorLocation(localPlayer);
                                FVector enemyPos = K2_GetActorLocation(closestEnemy);
                                FVector VectorDir = enemyPos - localPos;
                                
                                FRotator targetRotation = VectorToRotator(VectorDir);
                                
                                FRotator currentRotation = *reinterpret_cast<FRotator*>(playerController + OFFSET_CONTROL_ROTATION);
                                
                                float deltaYaw = NormalizeAxis(targetRotation.Yaw - currentRotation.Yaw);
                                float deltaPitch = NormalizeAxis(targetRotation.Pitch - currentRotation.Pitch);
                                
                                // 7. Movimiento Suave Nativo
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

    if (orig_ProcessEvent) {
        orig_ProcessEvent(_this, function, parms);
    }
}

// ============================================================================
// [8. PROTOCOLO DE ESTABILIDAD JAILED (INYECCIÓN QUAD-LOCK)]
// ============================================================================

void BackgroundInjectionThread() {
    printf("[LOG] Base Address encontrada: 0x%lX\n", reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)));
    
    // DELAY ABSOLUTO DE 15 SEGUNDOS
    std::this_thread::sleep_for(std::chrono::seconds(15));
    
    GetWeaponID = reinterpret_cast<int (*)(void*)>(getRealOffset(OFFSET_GET_WEAPON_ID));
    PickTarget = reinterpret_cast<uintptr_t (*)(void*, void*, double)>(getRealOffset(OFFSET_PICK_TARGET));
    K2_GetActorLocation = reinterpret_cast<FVector (*)(uintptr_t)>(getRealOffset(OFFSET_K2_GET_ACTOR_LOC));
    
    AddControllerYawInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_YAW_INPUT));
    AddControllerPitchInput = reinterpret_cast<void (*)(void*, float)>(getRealOffset(OFFSET_ADD_PITCH_INPUT));

    // UI: Botón flotante SIEMPRE tras 15 segundos
    InjectMasterSwitchUI();
    printf("[LOG] Interfaz Master Switch Inyectada.\n");

    bool hookApplied = false;

    // Bucle constante de escaneo (Cada 1 segundo)
    while (!hookApplied) {
        std::this_thread::sleep_for(std::chrono::seconds(1));

        uintptr_t localPlayerBase = getRealOffset(OFFSET_LOCAL_PLAYER);
        if (!IS_VALID_PTR(localPlayerBase)) continue;
        
        uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(localPlayerBase);
        if (IS_VALID_PTR(localPlayer)) {
            
            // Acceso al PlayerController usando el offset 0x548 proporcionado
            uintptr_t playerController = *reinterpret_cast<uintptr_t*>(localPlayer + OFFSET_PLAYER_CONTROLLER); 
            if (IS_VALID_PTR(playerController)) {
                
                // Shadow VTable Swap directamente en PlayerController (Heap Cloning)
                hookApplied = ApplyShadowVTableHook(reinterpret_cast<void*>(playerController), 
                                                    OFFSET_PROCESS_EVENT, 
                                                    reinterpret_cast<void*>(hooked_ProcessEvent), 
                                                    reinterpret_cast<void**>(&orig_ProcessEvent));
                                              
                if (hookApplied) {
                    printf("[LOG] Shadow VTable Hook aplicado con éxito en el PlayerController!\n");
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
