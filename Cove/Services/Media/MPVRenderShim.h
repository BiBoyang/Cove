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

/// Drains mpv's render dispatch queue once (mpv_render_context_update).
/// The calling thread must hold a current CGL context — the layer's
/// wrapper makes one current around this call. Returns the update flags
/// mpv reported; callers that only need the drain (the screenshot-raw
/// reply path) ignore them.
- (uint64_t)drainRenderDispatch;

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

/// Makes this layer's own CGL context current, drains mpv's render
/// dispatch queue once through the renderer, and restores the previous
/// context. This is what services a parked `screenshot-raw` reply when
/// playback is paused and no layer redraw happens to drain it. Main
/// thread only, like the rest of the shim.
- (void)drainRenderDispatch;

/// Forces the lazy CGL pixel format / context pair into existence WITHOUT
/// a window. Core Animation only runs the copyCGL* hooks when it actually
/// draws the layer, i.e. when the layer is hosted in a visible window; a
/// headless thumbnail capture session has none, so drainRenderDispatch
/// would early-return on a nil context forever and every screenshot-raw
/// would time out (SPIKE-headless-video-thumbnail, 2026-09-21). One call
/// after creation is enough — the context then lives for the layer's
/// lifetime exactly as if a draw had created it.
- (void)prepareHeadlessGLContext;

@end

NS_ASSUME_NONNULL_END

#pragma clang diagnostic pop

#endif /* MPVRenderShim_h */
