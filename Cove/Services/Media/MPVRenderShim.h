#ifndef MPVRenderShim_h
#define MPVRenderShim_h

#import <Foundation/Foundation.h>

// CAOpenGLLayer and the CGL API are deprecated since macOS 10.14. This
// shim is the single place that absorbs those deprecation warnings so the
// Swift side only ever sees a plain CALayer subclass and block callbacks.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <QuartzCore/CAOpenGLLayer.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps an mpv render context (OpenGL API) and renders into a
/// CAOpenGLLayer-provided CGL context. All methods must be called on the
/// main thread; mpv's internal update callback is the only cross-thread
/// edge and it hops to the main queue before touching anything.
@interface MPVGLRenderer : NSObject

/// Creates the render context on an already-initialized mpv handle.
/// Returns nil when mpv rejects the OpenGL render API.
/// `updateHandler` is invoked on the main queue every time mpv has a new
/// frame ready; typical body is `layer.mpvNeedsDisplay()`.
- (nullable instancetype)initWithMPVHandle:(void *)handle
                             updateHandler:(void (^)(void))updateHandler;

/// Draws the current mpv frame into the CAOpenGLLayer-provided context.
/// The drawable FBO and viewport are discovered from GL state (on modern
/// macOS the layer's drawable is NOT FBO 0 — rendering to 0 yields
/// GL_INVALID_FRAMEBUFFER_OPERATION and a black screen; IINA does the same
/// discovery).
- (void)renderInCGLContext:(CGLContextObj)context;

/// Tears down the render context. Must be called before
/// mpv_terminate_destroy on the owning handle.
- (void)invalidate;

@end

/// CAOpenGLLayer subclass whose draw calls forward to an MPVGLRenderer.
@interface MPVVideoLayer : CAOpenGLLayer

@property(nonatomic, weak, nullable) MPVGLRenderer *renderer;

/// Marks the layer dirty on the main thread; also safe to call after the
/// renderer went away (draw then no-ops on a black frame).
- (void)mpvNeedsDisplay;

@end

NS_ASSUME_NONNULL_END

#pragma clang diagnostic pop

#endif /* MPVRenderShim_h */
