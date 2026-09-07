// libmpv-gl-probe.c — minimal GL render probe for the self-built forest.
//
// Validates the SPIKE-video-playback.md conclusion-3 path against
// Vendor/libmpv-self: dlopen libmpv, vo=libmpv before mpv_initialize, a
// temporary current CGL context while creating/freeing the render context
// (mpv calls glGetString through the current context; without one it
// segfaults), GL symbols resolved via CFBundleGetFunctionPointerForName on
// com.apple.opengl (OpenGL.framework is not linked for GL entry points).
//
// Usage: libmpv-gl-probe /abs/path/to/libmpv.2.dylib
// Exit 0 + "PROBE_OK" on success.

#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <OpenGL/OpenGL.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

typedef mpv_handle *(*mpv_create_fn)(void);
typedef unsigned long (*mpv_client_api_version_fn)(void);
typedef int (*mpv_set_option_string_fn)(mpv_handle *, const char *, const char *);
typedef int (*mpv_initialize_fn)(mpv_handle *);
typedef int (*mpv_render_context_create_fn)(mpv_render_context **, mpv_handle *, mpv_render_param *);
typedef void (*mpv_render_context_free_fn)(mpv_render_context *);
typedef void (*mpv_terminate_destroy_fn)(mpv_handle *);
typedef const char *(*mpv_error_string_fn)(int);

static void *get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    if (!bundle) return NULL;
    CFStringRef cfname = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
    void *addr = CFBundleGetFunctionPointerForName(bundle, cfname);
    CFRelease(cfname);
    return addr;
}

static void *sym(void *h, const char *name) {
    void *p = dlsym(h, name);
    if (!p) fprintf(stderr, "missing symbol: %s\n", name);
    return p;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "Vendor/libmpv-self/libmpv.2.dylib";

    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen %s: %s\n", path, dlerror()); return 1; }

    mpv_create_fn p_create = (mpv_create_fn)sym(h, "mpv_create");
    mpv_client_api_version_fn p_api = (mpv_client_api_version_fn)sym(h, "mpv_client_api_version");
    mpv_set_option_string_fn p_set = (mpv_set_option_string_fn)sym(h, "mpv_set_option_string");
    mpv_initialize_fn p_init = (mpv_initialize_fn)sym(h, "mpv_initialize");
    mpv_render_context_create_fn p_rc_create = (mpv_render_context_create_fn)sym(h, "mpv_render_context_create");
    mpv_render_context_free_fn p_rc_free = (mpv_render_context_free_fn)sym(h, "mpv_render_context_free");
    mpv_terminate_destroy_fn p_destroy = (mpv_terminate_destroy_fn)sym(h, "mpv_terminate_destroy");
    mpv_error_string_fn p_err = (mpv_error_string_fn)sym(h, "mpv_error_string");
    if (!p_create || !p_api || !p_set || !p_init || !p_rc_create || !p_rc_free || !p_destroy || !p_err)
        return 1;

    mpv_handle *mpv = p_create();
    if (!mpv) { fprintf(stderr, "mpv_create failed\n"); return 1; }

    // Render API requires vo=libmpv set BEFORE mpv_initialize (SPIKE root cause 2).
    if (p_set(mpv, "vo", "libmpv") < 0) { fprintf(stderr, "set vo failed\n"); return 1; }
    p_set(mpv, "config", "no");
    p_set(mpv, "terminal", "no");

    int err = p_init(mpv);
    if (err < 0) { fprintf(stderr, "mpv_initialize: %s\n", p_err(err)); return 1; }
    printf("client api version: %lu\n", p_api());

    // Temporary current CGL context (SPIKE root cause 1).
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAAccelerated,
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFADoubleBuffer,
        kCGLPFABackingStore,
        kCGLPFAAllowOfflineRenderers,
        (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj pix = NULL;
    GLint npix = 0;
    if (CGLChoosePixelFormat(attrs, &pix, &npix) != kCGLNoError || !pix) {
        fprintf(stderr, "CGLChoosePixelFormat failed\n"); return 1;
    }
    CGLContextObj cgl = NULL;
    if (CGLCreateContext(pix, NULL, &cgl) != kCGLNoError || !cgl) {
        fprintf(stderr, "CGLCreateContext failed\n"); return 1;
    }
    CGLContextObj prev = CGLGetCurrentContext();
    CGLSetCurrentContext(cgl);

    mpv_opengl_init_params gl_init = { get_proc_address, NULL };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    mpv_render_context *rc = NULL;
    err = p_rc_create(&rc, mpv, params);
    printf("render_context_create: %d (%s)\n", err, err == 0 ? "success" : p_err(err));

    if (rc) p_rc_free(rc);
    CGLSetCurrentContext(prev);
    CGLDestroyContext(cgl);
    CGLDestroyPixelFormat(pix);
    p_destroy(mpv);

    if (err != 0) return 2;
    printf("PROBE_OK\n");
    return 0;
}
