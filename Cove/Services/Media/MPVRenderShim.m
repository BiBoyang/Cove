#import "MPVRenderShim.h"

// See the header: every deprecated CGL/OpenGL call lives behind this pragma.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import <CoreFoundation/CoreFoundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <mpv/render_gl.h>

/// Owns the update block for as long as mpv can legally invoke the update
/// callback. The cookie passed to mpv is a RETAINED pointer to this box,
/// released only after mpv_render_context_free returns — mpv guarantees no
/// callbacks after free, but a callback already in flight on an mpv thread
/// while invalidate() runs on the main thread must still find a live box.
/// (Reaching through a possibly-dead MPVGLRenderer here was a
/// use-after-free that corrupted the malloc freelist; xzone reported it at
/// the next unrelated allocation, i.e. "crash on window close".)
@interface MPVRenderUpdateBox : NSObject
@property(nonatomic, copy) void (^handler)(void);
@end
@implementation MPVRenderUpdateBox
@end

@interface MPVGLRenderer ()
@property(nonatomic, strong) MPVRenderUpdateBox *updateBox;
@end

/// mpv looks GL symbols up through this callback. Core OpenGL entry points
/// live in the com.apple.opengl bundle; resolving them lazily avoids
/// linking the deprecated OpenGL framework directly.
static void *coveGLGetProcAddress(void *ctx, const char *name) {
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    if (!bundle) {
        return NULL;
    }
    CFStringRef symbolName = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
    void *address = CFBundleGetFunctionPointerForName(bundle, symbolName);
    CFRelease(symbolName);
    return address;
}

/// mpv fires this on an internal mpv thread when a new frame is available.
/// Hop to the main queue before touching the layer; the box outlives any
/// in-flight call by construction (see MPVRenderUpdateBox).
static void coveRenderUpdateCallback(void *ctx) {
    MPVRenderUpdateBox *box = (__bridge MPVRenderUpdateBox *)ctx;
    dispatch_async(dispatch_get_main_queue(), box.handler);
}

/// The pixel format attribute set shared by the throwaway context (used at
/// render-context create/free) and MPVVideoLayer's own context, so mpv's
/// capability probing always sees the same GL personality.
static const CGLPixelFormatAttribute coveGLPixelFormatAttrs[] = {
    kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
    kCGLPFAAccelerated,
    kCGLPFADoubleBuffer,
    kCGLPFABackingStore,
    kCGLPFAAllowOfflineRenderers,
    (CGLPixelFormatAttribute)0,
};

/// Runs `block` with a throwaway CGL context made current, restoring the
/// previous context afterwards. Required because the GL symbols mpv gets
/// from get_proc_address are libGL trampolines that dispatch through the
/// *current* context: mpv_render_context_create/free call entry points
/// like glGetString, and with no current context they dereference a null
/// CGL context struct (EXC_BAD_ACCESS in libGL). IINA does the same dance.
static void coveWithCurrentGLContext(void (^block)(void)) {
    CGLPixelFormatObj pixelFormat = NULL;
    GLint pixelFormatCount = 0;
    if (CGLChoosePixelFormat(coveGLPixelFormatAttrs, &pixelFormat, &pixelFormatCount) != kCGLNoError || !pixelFormat) {
        block();
        return;
    }
    CGLContextObj context = NULL;
    if (CGLCreateContext(pixelFormat, NULL, &context) != kCGLNoError || !context) {
        CGLReleasePixelFormat(pixelFormat);
        block();
        return;
    }
    CGLContextObj previous = CGLGetCurrentContext();
    CGLSetCurrentContext(context);
    block();
    CGLSetCurrentContext(previous);
    CGLReleaseContext(context);
    CGLReleasePixelFormat(pixelFormat);
}

@implementation MPVGLRenderer {
    mpv_render_context *_renderContext;
    /// Retained cookie for the update callback; see init/invalidate.
    void *_updateCookie;
}

- (instancetype)initWithMPVHandle:(void *)handle
                    updateHandler:(void (^)(void))updateHandler {
    self = [super init];
    if (!self) {
        return nil;
    }
    _updateBox = [[MPVRenderUpdateBox alloc] init];
    _updateBox.handler = updateHandler;

    __block int createResult = -1;
    coveWithCurrentGLContext(^{
        mpv_opengl_init_params glInit = {
            .get_proc_address = &coveGLGetProcAddress,
            .get_proc_address_ctx = NULL,
        };
        int advancedControl = 1;
        mpv_render_param params[] = {
            { .type = MPV_RENDER_PARAM_API_TYPE, .data = MPV_RENDER_API_TYPE_OPENGL },
            { .type = MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, .data = &glInit },
            { .type = MPV_RENDER_PARAM_ADVANCED_CONTROL, .data = &advancedControl },
            { .type = MPV_RENDER_PARAM_INVALID, .data = NULL },
        };
        createResult = mpv_render_context_create(&self->_renderContext, (mpv_handle *)handle, params);
    });
    if (createResult < 0) {
        return nil;
    }
    // Retain the box as the callback cookie; balanced in invalidate AFTER
    // mpv_render_context_free returns (mpv guarantees no callbacks beyond
    // that point, so an in-flight callback always finds a live box).
    _updateCookie = (void *)CFBridgingRetain(_updateBox);
    mpv_render_context_set_update_callback(_renderContext, &coveRenderUpdateCallback, _updateCookie);
    return self;
}

- (void)renderInCGLContext:(CGLContextObj)context {
    if (!_renderContext) {
        return;
    }
    CGLSetCurrentContext(context);

    // Clear first so undrawn edges stay black even if mpv skips a pass.
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // On modern macOS the CAOpenGLLayer drawable is a real FBO, NOT 0.
    // Rendering to 0 produced GL_INVALID_FRAMEBUFFER_OPERATION and a black
    // screen while audio kept playing. Discover the target from GL state
    // (same approach as IINA's ViewLayer).
    GLint boundFBO = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &boundFBO);
    GLint viewport[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[2] <= 0 || viewport[3] <= 0) {
        // Fallback: viewport not established yet; derive from layer bounds.
        // (drawInCGLContext normally guarantees a valid viewport.)
        return;
    }

    mpv_opengl_fbo fbo = {
        .fbo = (int)boundFBO,
        .w = (int)viewport[2],
        .h = (int)viewport[3],
        .internal_format = 0,
    };
    int flipY = 1;
    mpv_render_param params[] = {
        { .type = MPV_RENDER_PARAM_OPENGL_FBO, .data = &fbo },
        { .type = MPV_RENDER_PARAM_FLIP_Y, .data = &flipY },
        { .type = MPV_RENDER_PARAM_INVALID, .data = NULL },
    };
    mpv_render_context_render(_renderContext, params);
    // With advanced control on, mpv needs the swap report for frame timing.
    mpv_render_context_report_swap(_renderContext);
}

- (void)invalidate {
    if (_renderContext) {
        // Stop the update callback first so no NEW dispatch can start.
        mpv_render_context_set_update_callback(_renderContext, NULL, NULL);
        // Free may emit GL deletes; same current-context requirement as create.
        coveWithCurrentGLContext(^{
            mpv_render_context_free(self->_renderContext);
        });
        _renderContext = NULL;
        // Only after free returns is the callback guaranteed dead; release
        // the retained box now so an in-flight callback never saw a
        // dangling cookie.
        if (_updateCookie) {
            CFRelease((CFTypeRef)_updateCookie);
            _updateCookie = NULL;
        }
    }
}

- (void)dealloc {
    [self invalidate];
}

@end

@implementation MPVVideoLayer {
    CGLPixelFormatObj _pixelFormat;
    CGLContextObj _context;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // mpv drives redraws through the update callback; the layer must
        // not wait for the run loop's display timer.
        self.asynchronous = YES;
        self.needsDisplayOnBoundsChange = YES;
        self.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        self.contentsGravity = kCAGravityResizeAspect;
    }
    return self;
}

- (void)mpvNeedsDisplay {
    [self setNeedsDisplay];
}

// Pin the layer's GL personality to the same attribute set the shim uses
// for its throwaway contexts (core profile 3.2 etc.), so the context mpv
// probed at create time matches the one we draw with. IINA overrides the
// same two CAOpenGLLayer hooks.
//
// Ownership: these overrides follow true copy semantics — CAOpenGLLayer
// releases what they hand back. Returning the cached object unretained
// while ALSO releasing it in dealloc is a double free (xzone malloc
// breakpoint on window close, detected at the next unrelated allocation).
// So hand out a real +1 with the CGL retain APIs (CGL objects are NOT
// CoreFoundation types; CFRetain on one crashes in objc_retain), and
// dealloc releases only the layer's own cached reference.
- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
    if (!_pixelFormat) {
        GLint count = 0;
        if (CGLChoosePixelFormat(coveGLPixelFormatAttrs, &_pixelFormat, &count) != kCGLNoError) {
            _pixelFormat = NULL;
        }
    }
    return _pixelFormat ? CGLRetainPixelFormat(_pixelFormat) : NULL;
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf {
    if (!_context) {
        CGLCreateContext(pf, NULL, &_context);
    }
    return _context ? CGLRetainContext(_context) : NULL;
}

- (void)drawInCGLContext:(CGLContextObj)ctx
             pixelFormat:(CGLPixelFormatObj)pf
            forLayerTime:(CFTimeInterval)t
             displayTime:(nullable const CVTimeStamp *)ts {
    [self.renderer renderInCGLContext:ctx];
}

- (void)dealloc {
    if (_context) {
        CGLReleaseContext(_context);
    }
    if (_pixelFormat) {
        CGLReleasePixelFormat(_pixelFormat);
    }
}

@end

#pragma clang diagnostic pop
