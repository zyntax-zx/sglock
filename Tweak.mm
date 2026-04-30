#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdint.h>
#include <cmath>
#include <cstdio>
#include <thread>
#include <chrono>
#include <unistd.h>
#include <cstring>

// ============================================================================
// [1. ESTRUCTURAS MATEMÁTICAS]
// ============================================================================

struct FVector {
    float X, Y, Z;
    FVector operator-(const FVector& o) const { return {X-o.X, Y-o.Y, Z-o.Z}; }
};

struct FRotator { float Pitch, Yaw, Roll; };

static FRotator VecToRot(FVector d) {
    return { atan2f(d.Z, sqrtf(d.X*d.X+d.Y*d.Y)) * (180.f/(float)M_PI),
             atan2f(d.Y, d.X) * (180.f/(float)M_PI), 0.f };
}

static float NormAxis(float a) {
    while (a >  180.f) a -= 360.f;
    while (a < -180.f) a += 360.f;
    return a;
}

// ============================================================================
// [2. SDK ANCHORS — TABLA DE LA VERDAD v2.0]
// ============================================================================

// Anclas del motor
constexpr uintptr_t ADDR_GUOBJECT_ARRAY   = 0x9515A0; // FUObjectArray
constexpr uintptr_t ADDR_GWORLD           = 0x951770; // UWorld*
constexpr uintptr_t VTABLE_PROCESS_EVENT  = 0x260;    // Índice en VTable

// Funciones nativas
constexpr uintptr_t OFF_GET_WEAPON_ID     = 0x4c546c;
constexpr uintptr_t OFF_PICK_TARGET       = 0x0b27f0;
constexpr uintptr_t OFF_K2_ACTOR_LOC      = 0x1b844c;
constexpr uintptr_t OFF_ADD_YAW           = 0x1e3294;
constexpr uintptr_t OFF_ADD_PITCH         = 0x1e33dc;
constexpr uintptr_t ADDR_STR_DRAW_HUD    = 0x90cb2a;

// Offsets UObject/UWorld
constexpr uintptr_t OFF_HEALTH_STATE      = 0x67c;
constexpr uintptr_t OFF_CTRL_ROTATION     = 0x2e8;
constexpr int       STATE_KNOCKED         = 0x92f92;

// FUObjectArray layout (UE4 ARM64)
constexpr uintptr_t OFF_OBJARRAY_DATA     = 0x10; // ObjObjects.Objects ptr
constexpr uintptr_t OFF_OBJARRAY_NUM      = 0x18; // NumElements
constexpr uintptr_t FUOBJECTITEM_SIZE     = 0x18; // sizeof(FUObjectItem)

// GWorld → HUD path
constexpr uintptr_t OFF_GAME_INSTANCE     = 0x180;
constexpr uintptr_t OFF_LOCAL_PLAYERS     = 0x38;
constexpr uintptr_t OFF_PLAYER_CTRL       = 0x30;
constexpr uintptr_t OFF_HUD               = 0x2b0;

#define IS_VALID_PTR(p) ((uintptr_t)(p) > 0x100000000ULL)

static inline uintptr_t BASE() {
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0));
}
static inline uintptr_t OFF(uintptr_t o) { return BASE() + o; }

// ============================================================================
// [3. ESTADO GLOBAL]
// ============================================================================

static bool g_Active = false;

// ============================================================================
// [4. SDK — GUObjectArray ITERATOR]
// ============================================================================


// Navegación por GWorld → GameInstance → LocalPlayers[0] → PlayerController → HUD
static uintptr_t FindHUDViaGWorld() {
    uintptr_t worldPtr = *reinterpret_cast<uintptr_t*>(OFF(ADDR_GWORLD));
    if (!IS_VALID_PTR(worldPtr)) {
        printf("[SDK] GWorld invalido.\n");
        return 0;
    }
    printf("[SDK] GWorld: 0x%lX\n", worldPtr);

    uintptr_t gameInst = *reinterpret_cast<uintptr_t*>(worldPtr + OFF_GAME_INSTANCE);
    if (!IS_VALID_PTR(gameInst)) {
        printf("[SDK] GameInstance invalido.\n");
        return 0;
    }

    // LocalPlayers es un TArray — primer elemento
    uintptr_t lpArray = *reinterpret_cast<uintptr_t*>(gameInst + OFF_LOCAL_PLAYERS);
    if (!IS_VALID_PTR(lpArray)) {
        printf("[SDK] LocalPlayers invalido.\n");
        return 0;
    }

    uintptr_t localPlayer = *reinterpret_cast<uintptr_t*>(lpArray);
    if (!IS_VALID_PTR(localPlayer)) {
        printf("[SDK] LocalPlayer[0] invalido.\n");
        return 0;
    }
    printf("[SDK] LocalPlayer: 0x%lX\n", localPlayer);

    uintptr_t controller = *reinterpret_cast<uintptr_t*>(localPlayer + OFF_PLAYER_CTRL);
    if (!IS_VALID_PTR(controller)) {
        printf("[SDK] PlayerController invalido.\n");
        return 0;
    }
    printf("[SDK] PlayerController: 0x%lX\n", controller);

    uintptr_t hud = *reinterpret_cast<uintptr_t*>(controller + OFF_HUD);
    if (!IS_VALID_PTR(hud)) {
        printf("[SDK] HUD invalido.\n");
        return 0;
    }
    printf("[SDK] HUD: 0x%lX\n", hud);

    return hud;
}

// ============================================================================
// [5. INTERFAZ GRÁFICA NATIVA]
// ============================================================================

@interface SGLockButton : UIButton
@end

@implementation SGLockButton
- (void)toggle {
    g_Active = !g_Active;
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
                                       initWithStyle:UIImpactFeedbackStyleMedium];
    [gen prepare]; [gen impactOccurred];
    self.backgroundColor = g_Active ? UIColor.greenColor : UIColor.redColor;
    printf("[Tweak] SGLock is now %s\n", g_Active ? "ENABLED" : "DISABLED");
}
- (void)pan:(UIPanGestureRecognizer*)r {
    if (r.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [r translationInView:self.superview];
        self.center = CGPointMake(self.center.x+t.x, self.center.y+t.y);
        [r setTranslation:CGPointZero inView:self.superview];
    }
}
@end

static void InjectUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows)
            if (w.isKeyWindow) { win = w; break; }
        if (!win) return;

        SGLockButton *btn = [SGLockButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(20, 100, 44, 44);
        btn.layer.cornerRadius = 22;
        btn.backgroundColor    = UIColor.redColor;
        btn.layer.borderWidth  = 2;
        btn.layer.borderColor  = UIColor.whiteColor.CGColor;
        btn.clipsToBounds = YES;
        btn.alpha = 0.85f;
        [btn addTarget:btn action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                        initWithTarget:btn action:@selector(pan:)];
        [btn addGestureRecognizer:pan];
        [win addSubview:btn];
        printf("[Tweak] UI Master Switch inyectada.\n");
    });
}

// ============================================================================
// [6. FIRMAS NATIVAS]
// ============================================================================

static int      (*GetWeaponID)(void*);
static uintptr_t (*PickTarget)(void*, void*, double);
static FVector   (*K2_GetActorLocation)(uintptr_t);
static void     (*AddYaw)(void*, float);
static void     (*AddPitch)(void*, float);

// ============================================================================
// [7. SYMBOL REBINDING (PAC-Safe — __DATA,__la_symbol_ptr)]
// ============================================================================

static const char* kPESymbol = "_ZN7UObject12ProcessEventEP9UFunctionPv";

static void (*orig_PE)(void*, void*, void*) = nullptr;

static bool RebindProcessEvent(void* newFunc, void** origOut) {
    const mach_header_64* mh = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(0));
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);

    const symtab_command*   symCmd  = nullptr;
    const dysymtab_command* dsymCmd = nullptr;

    const load_command* lc = reinterpret_cast<const load_command*>(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++,
         lc = reinterpret_cast<const load_command*>((uint8_t*)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SYMTAB)   symCmd  = (symtab_command*)lc;
        if (lc->cmd == LC_DYSYMTAB) dsymCmd = (dysymtab_command*)lc;
    }
    if (!symCmd || !dsymCmd) return false;

    const char*     strtab = (const char*)(slide + symCmd->stroff);
    const nlist_64* nltab  = (const nlist_64*)(slide + symCmd->symoff);
    const uint32_t* indir  = (const uint32_t*)(slide + dsymCmd->indirectsymoff);

    lc = reinterpret_cast<const load_command*>(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++,
         lc = reinterpret_cast<const load_command*>((uint8_t*)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const segment_command_64* seg = (segment_command_64*)lc;
        if (strncmp(seg->segname, "__DATA", 6) != 0 &&
            strncmp(seg->segname, "__DATA_CONST", 12) != 0) continue;

        const section_64* sect = (section_64*)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            uint8_t t = sect->flags & SECTION_TYPE;
            if (t != S_LAZY_SYMBOL_POINTERS && t != S_NON_LAZY_SYMBOL_POINTERS) continue;

            uint32_t    n     = (uint32_t)(sect->size / 8);
            uintptr_t*  ptrs  = (uintptr_t*)(slide + sect->addr);

            for (uint32_t k = 0; k < n; k++) {
                uint32_t idx = indir[sect->reserved1 + k];
                if (idx & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
                if (idx >= symCmd->nsyms) continue;
                if (strcmp(strtab + nltab[idx].n_un.n_strx, kPESymbol) != 0) continue;

                if (origOut) *origOut = (void*)ptrs[k];
                ptrs[k] = (uintptr_t)newFunc;
                printf("[Tweak] Simbolo ProcessEvent re-enlazado correctamente (PAC-Safe).\n");
                return true;
            }
        }
    }
    printf("[LOG] Simbolo ProcessEvent no encontrado en __DATA. El juego lo enlaza estaticamente.\n");
    return false;
}

// ============================================================================
// [8. HOOK DE PROCESSEVENT — AIMLOCK PERSISTENTE]
// ============================================================================

static void hooked_PE(void* _this, void* func, void* parms) {
    // Regla de Oro
    if (!g_Active || !_this || !func) {
        if (orig_PE) orig_PE(_this, func, parms);
        return;
    }

    // Resolver evento ReceiveDrawHUD
    char* drawHUDStr = (char*)OFF(ADDR_STR_DRAW_HUD);
    if (!IS_VALID_PTR(drawHUDStr) || memcmp(func, drawHUDStr, 34) != 0) {
        if (orig_PE) orig_PE(_this, func, parms);
        return;
    }

    // Navegar GWorld → HUD → PlayerController
    uintptr_t world = *reinterpret_cast<uintptr_t*>(OFF(ADDR_GWORLD));
    if (!IS_VALID_PTR(world)) { if (orig_PE) orig_PE(_this, func, parms); return; }

    uintptr_t gi = *reinterpret_cast<uintptr_t*>(world + OFF_GAME_INSTANCE);
    if (!IS_VALID_PTR(gi)) { if (orig_PE) orig_PE(_this, func, parms); return; }

    uintptr_t lpArr = *reinterpret_cast<uintptr_t*>(gi + OFF_LOCAL_PLAYERS);
    if (!IS_VALID_PTR(lpArr)) { if (orig_PE) orig_PE(_this, func, parms); return; }

    uintptr_t lp = *reinterpret_cast<uintptr_t*>(lpArr);
    if (!IS_VALID_PTR(lp)) { if (orig_PE) orig_PE(_this, func, parms); return; }

    uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(lp + OFF_PLAYER_CTRL);
    if (!IS_VALID_PTR(ctrl)) { if (orig_PE) orig_PE(_this, func, parms); return; }

    // Filtro de Arma
    int wid = GetWeaponID((void*)lp);
    bool isShotgun = (((wid - 0x19641) < 4) || (wid == 0x196a5));
    if (!isShotgun) { if (orig_PE) orig_PE(_this, func, parms); return; }

    // Buscar Objetivo
    uint8_t p1[16]={}, p2[16]={};
    uintptr_t enemy = PickTarget(p1, p2, 0.0);
    if (!IS_VALID_PTR(enemy)) { if (orig_PE) orig_PE(_this, func, parms); return; }

    int hpState = *reinterpret_cast<int*>(enemy + OFF_HEALTH_STATE);
    if (hpState == STATE_KNOCKED) { if (orig_PE) orig_PE(_this, func, parms); return; }

    // Cálculo de Rotación
    FVector myPos  = K2_GetActorLocation(lp);
    FVector enPos  = K2_GetActorLocation(enemy);
    FRotator tgt   = VecToRot(enPos - myPos);
    FRotator cur   = *reinterpret_cast<FRotator*>(ctrl + OFF_CTRL_ROTATION);

    float dY = NormAxis(tgt.Yaw   - cur.Yaw);
    float dP = NormAxis(tgt.Pitch - cur.Pitch);

    constexpr float SMOOTH = 0.5f;
    if (AddYaw && AddPitch) {
        AddYaw  ((void*)ctrl, dY * SMOOTH);
        AddPitch((void*)ctrl, dP * SMOOTH);
    }

    if (orig_PE) orig_PE(_this, func, parms);
}

// ============================================================================
// [9. PROTOCOLO DE ESTABILIDAD JAILED (QUAD-LOCK)]
// ============================================================================

static void InjectionThread() {
    printf("[LOG] SGLock iniciado. Base: 0x%lX\n", BASE());

    // FASE 1 — 15s delay absoluto
    std::this_thread::sleep_for(std::chrono::seconds(15));

    // Resolver funciones nativas
    GetWeaponID         = (int(*)(void*))          OFF(OFF_GET_WEAPON_ID);
    PickTarget          = (uintptr_t(*)(void*,void*,double)) OFF(OFF_PICK_TARGET);
    K2_GetActorLocation = (FVector(*)(uintptr_t))  OFF(OFF_K2_ACTOR_LOC);
    AddYaw              = (void(*)(void*,float))   OFF(OFF_ADD_YAW);
    AddPitch            = (void(*)(void*,float))   OFF(OFF_ADD_PITCH);

    // FASE 2 — UI en main thread (siempre)
    InjectUI();

    // FASE 3 — Symbol Rebinding PAC-Safe sobre __DATA
    bool hooked = RebindProcessEvent((void*)hooked_PE, (void**)&orig_PE);

    if (!hooked) {
        // Fallback: buscar HUD via GWorld e intentar VTable instance swap
        printf("[LOG] Intentando VTable swap via GWorld...\n");
        int retries = 0;
        while (retries++ < 30) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            uintptr_t hud = FindHUDViaGWorld();
            if (!IS_VALID_PTR(hud)) continue;

            // Shadow VTable (Heap clone — no mprotect)
            uintptr_t* origVT = *reinterpret_cast<uintptr_t**>(hud);
            if (!IS_VALID_PTR(origVT)) continue;

            int idx = VTABLE_PROCESS_EVENT / sizeof(uintptr_t);
            uintptr_t* shadow = new uintptr_t[400];
            memcpy(shadow, origVT, 400 * sizeof(uintptr_t));

            orig_PE = (void(*)(void*,void*,void*))origVT[idx];
            shadow[idx] = (uintptr_t)hooked_PE;
            *reinterpret_cast<uintptr_t**>(hud) = shadow;

            printf("[LOG] VTable Shadow Hook aplicado en HUD via GWorld.\n");
            break;
        }
    }
}

__attribute__((constructor))
static void init() {
    if (!_dyld_get_image_header(0)) return;
    std::thread(InjectionThread).detach();
}
