#ifndef MPVBridgingHeader_h
#define MPVBridgingHeader_h

// libmpv C API surface used by the app target: client core, the custom
// stream protocol (stream_cb) and the OpenGL render API.
#include <mpv/client.h>
#include <mpv/stream_cb.h>
#include <mpv/render_gl.h>

// Thin ObjC wrapper absorbing all deprecated CGL/CAOpenGLLayer usage.
#import "MPVRenderShim.h"

#endif /* MPVBridgingHeader_h */
