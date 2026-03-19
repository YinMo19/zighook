#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

__declspec(dllexport) __declspec(noinline) int target_add(int a, int b) {
    return a + b;
}

typedef void (__cdecl *hook_install_fn)(void);

int main(void) {
    volatile int a = 2;
    volatile int b = 3;

    HMODULE hook = LoadLibraryA(".\\hook.dll");
    if (hook == NULL) {
        fprintf(stderr, "load_hook_failed=%lu\n", (unsigned long)GetLastError());
        return 1;
    }

    hook_install_fn install = (hook_install_fn)GetProcAddress(hook, "zighook_example_install");
    if (install == NULL) {
        fprintf(stderr, "resolve_install_failed=%lu\n", (unsigned long)GetLastError());
        return 1;
    }

    install();
    printf("result=%d\n", target_add(a, b));
    return 0;
}
