// Loads a built NVMTLDriver into this process (no install) and runs one test.
// usage: harness <path/to/NVMTLDriver> <test>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <unistd.h>
#include <signal.h>

static id<MTLDevice> dev;
static void timeout_hit(int s) { (void)s; const char m[] = "RESULT TIMEOUT (hang)\n"; write(1, m, sizeof m - 1); _exit(124); }

static id<MTLComputePipelineState> pso(NSString *src, NSString *fn) {
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("RESULT FAIL library %s\n", e.description.UTF8String); exit(2); }
    id<MTLFunction> f = [lib newFunctionWithName:fn];
    id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:f error:&e];
    if (!p) { printf("RESULT FAIL pso %s\n", e.description.UTF8String); exit(2); }
    return p;
}

static NSString *kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void twice(device float *a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a[i] = a[i] * 2.0f + 1.0f; }\n"
    "kernel void rd(device const float4 *a [[buffer(0)]], device float *o [[buffer(1)]], constant uint &cnt [[buffer(2)]],"
    " uint i [[thread_position_in_grid]], uint n [[threads_per_grid]]) { float4 s = 0; for (uint k = i; k < cnt; k += n) s += a[k]; o[i] = s.x+s.y+s.z+s.w; }\n";

static int test_compute(void) {
    id<MTLComputePipelineState> p = pso(kSrc, @"twice");
    id<MTLCommandQueue> q = [dev newCommandQueue];
    const int n = 1 << 20;
    id<MTLBuffer> b = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    float *f = b.contents; for (int i = 0; i < n; i++) f[i] = i;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:p]; [e setBuffer:b offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    for (int i = 0; i < n; i++) if (f[i] != i * 2.0f + 1.0f) { printf("RESULT FAIL a[%d]=%f\n", i, f[i]); return 1; }
    printf("RESULT PASS compute %d floats correct, status %ld\n", n, (long)cb.status);
    return 0;
}

// Metal games wait on a command buffer from a completion handler; Apple returns once it completed.
static int test_handler_wait(void) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl fillBuffer:b range:NSMakeRange(0, 4096) value:7]; [bl endEncoding];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { [c waitUntilCompleted]; dispatch_semaphore_signal(done); }];
    [cb commit];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC))) { printf("RESULT FAIL handler waiting on its own buffer hung\n"); return 1; }
    [cb waitUntilCompleted];
    printf("RESULT PASS handler can wait on its own command buffer\n");
    return 0;
}

static int test_nocopy_dealloc(void) {
    const size_t len = 64 * 1024;
    void *mem = NULL; posix_memalign(&mem, 16384, len); memset(mem, 3, len);
    __block void *gotP = (void *)1; __block NSUInteger gotL = 1;
    @autoreleasepool {
        id<MTLBuffer> b = [dev newBufferWithBytesNoCopy:mem length:len options:MTLResourceStorageModeShared
                                            deallocator:^(void *p, NSUInteger l) { gotP = p; gotL = l; }];
        if (!b) { printf("RESULT FAIL nil buffer\n"); return 1; }
        b = nil;
    }
    for (int i = 0; i < 100 && gotP == (void *)1; i++) usleep(10000);
    if (gotP == mem && gotL == len) { printf("RESULT PASS deallocator got the caller's pointer and length\n"); free(mem); return 0; }
    printf("RESULT FAIL deallocator got (%p, %lu), expected (%p, %zu)\n", gotP, (unsigned long)gotL, mem, len);
    return 1;
}

static int test_events(void) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLSharedEvent> ev = [dev newSharedEvent];
    id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> a = [q commandBuffer];
    [a encodeWaitForEvent:ev value:1];
    id<MTLBlitCommandEncoder> bl = [a blitCommandEncoder]; [bl fillBuffer:b range:NSMakeRange(0, 4096) value:9]; [bl endEncoding];
    [a encodeSignalEvent:ev value:2];
    [a commit];
    usleep(100000);
    if (a.status == MTLCommandBufferStatusCompleted) { printf("RESULT FAIL ran before its wait was signalled\n"); return 1; }
    ev.signaledValue = 1;
    [a waitUntilCompleted];
    if (ev.signaledValue != 2 || ((uint8_t *)b.contents)[100] != 9) { printf("RESULT FAIL event %llu byte %u\n", ev.signaledValue, ((uint8_t *)b.contents)[100]); return 1; }
    printf("RESULT PASS shared event wait/signal ordering\n");
    return 0;
}

static double read_ms(MTLResourceOptions opt, size_t mb) {
    id<MTLComputePipelineState> p = pso(kSrc, @"rd");
    id<MTLCommandQueue> q = [dev newCommandQueue];
    size_t size = mb << 20;
    id<MTLBuffer> a = [dev newBufferWithLength:size options:opt];
    if (opt == MTLResourceStorageModeShared) memset(a.contents, 1, size);
    else { id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [c blitCommandEncoder];
           [bl fillBuffer:a range:NSMakeRange(0, size) value:1]; [bl endEncoding]; [c commit]; [c waitUntilCompleted]; }
    id<MTLBuffer> o = [dev newBufferWithLength:4 * 65536 options:MTLResourceStorageModeShared];
    uint32_t cnt = (uint32_t)(size / 16); double best = 1e9;
    for (int r = 0; r < 5; r++) {
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:p]; [e setBuffer:a offset:0 atIndex:0]; [e setBuffer:o offset:0 atIndex:1]; [e setBytes:&cnt length:4 atIndex:2];
        [e dispatchThreads:MTLSizeMake(65536, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { printf("RESULT FAIL status %ld\n", (long)cb.status); exit(1); }
        double t = cb.GPUEndTime - cb.GPUStartTime; if (t > 0 && t < best) best = t;
    }
    return best * 1000;
}

static int test_bandwidth(void) {
    double p = read_ms(MTLResourceStorageModePrivate, 256), s = read_ms(MTLResourceStorageModeShared, 256);
    printf("RESULT PASS read 256MB: private %.2f ms (%.0f GB/s), shared %.2f ms (%.1f GB/s)\n", p, 268.4 / p, s, 268.4 / s);
    return 0;
}

// Many small command buffers, each waited from a completion handler, from two threads at once.
static int test_stress(void) {
    id<MTLComputePipelineState> p = pso(kSrc, @"twice");
    __block int bad = 0;
    dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t t) {
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> b = [dev newBufferWithLength:4096 * 4 options:MTLResourceStorageModeShared];
        for (int it = 0; it < 300; it++) {
            float *f = b.contents; for (int i = 0; i < 4096; i++) f[i] = 1;
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:p]; [e setBuffer:b offset:0 atIndex:0];
            [e dispatchThreads:MTLSizeMake(4096, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [e endEncoding];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; }];
            [cb commit]; [cb waitUntilCompleted];
            if (cb.status != MTLCommandBufferStatusCompleted || f[4095] != 3.0f) __sync_fetch_and_add(&bad, 1);
        }
        (void)t;
    });
    if (bad) { printf("RESULT FAIL %d of 1200 wrong\n", bad); return 1; }
    printf("RESULT PASS 1200 command buffers on 4 threads\n");
    return 0;
}


// Many small uploads into one texture with GPU reads in between, as an atlas animation does. Each GPU read must
// see exactly the uploads made before it was committed, and the final readback must match a CPU reference.
// With NVMTL_ASYNC_TEX_UPLOAD=1 the uploads are left in flight, so this checks they still land in order.
static int test_texture_uploads(void) {
    enum { W = 256, H = 256, T = 16, N = 600, EVERY = 50 };
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void tcopy(texture2d<float, access::read> t [[texture(0)]], device uchar4 *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {"
        " o[g.y * 256 + g.x] = uchar4(t.read(g) * 255.0f + 0.5f); }\n";
    id<MTLComputePipelineState> p = pso(src, @"tcopy");
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:d];
    static uint32_t ref[W * H], tile[T * T];
    memset(ref, 0, sizeof ref);
    [tex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:ref bytesPerRow:W * 4];
    NSMutableArray *snaps = [NSMutableArray new], *bufs = [NSMutableArray new], *cbs = [NSMutableArray new];
    uint32_t seed = 12345;
    for (int i = 1; i <= N; i++) {
        seed = seed * 1103515245u + 12345u; uint32_t x = (seed >> 8) % (W - T + 1);
        seed = seed * 1103515245u + 12345u; uint32_t y = (seed >> 8) % (H - T + 1);
        uint32_t v = 0xFF000000u | (uint32_t)i * 2654435761u >> 8;
        for (int k = 0; k < T * T; k++) tile[k] = v;
        [tex replaceRegion:MTLRegionMake2D(x, y, T, T) mipmapLevel:0 withBytes:tile bytesPerRow:T * 4];
        for (int r = 0; r < T; r++) for (int c = 0; c < T; c++) ref[(y + r) * W + x + c] = v;
        if (i % EVERY == 0) {
            id<MTLBuffer> o = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:p]; [e setTexture:tex atIndex:0]; [e setBuffer:o offset:0 atIndex:0];
            [e dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [e endEncoding];
            // Metal forbids changing a texture while committed GPU work still reads it (Apple's GL waits for that
            // itself), so the read finishes before the next upload; the uploads themselves are never waited.
            [cb commit]; [cb waitUntilCompleted];
            [snaps addObject:[NSData dataWithBytes:ref length:sizeof ref]]; [bufs addObject:o]; [cbs addObject:cb];
        }
    }
    int bad = 0;
    for (NSUInteger k = 0; k < cbs.count; k++) {
        id<MTLCommandBuffer> cb = cbs[k]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { printf("RESULT FAIL GPU read %lu status %ld\n", (unsigned long)k, (long)cb.status); return 1; }
        if (memcmp([bufs[k] contents], [snaps[k] bytes], W * H * 4)) { bad++; printf("  GPU read %lu does not match the uploads made before it\n", (unsigned long)k); }
    }
    static uint32_t back[W * H];
    [tex getBytes:back bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    if (memcmp(back, ref, sizeof ref)) { printf("RESULT FAIL final readback differs from the uploads\n"); return 1; }
    if (bad) { printf("RESULT FAIL %d of %lu GPU reads saw the wrong uploads\n", bad, (unsigned long)cbs.count); return 1; }
    printf("RESULT PASS %d uploads, %lu interleaved GPU reads and the readback all match\n", N, (unsigned long)cbs.count);
    return 0;
}

// Frame-shaped upload cost: each "frame" queues ~2 ms of GPU work, then makes 20 small texture uploads.
static int test_texture_upload_bench(void) {
    id<MTLComputePipelineState> p = pso(kSrc, @"rd");
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> a = [dev newBufferWithLength:64 << 20 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> o = [dev newBufferWithLength:4 * 65536 options:MTLResourceStorageModePrivate];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:512 mipmapped:NO];
    id<MTLTexture> tex = [dev newTextureWithDescriptor:d];
    static uint32_t tile[16 * 16]; uint32_t cnt = (64 << 20) / 16;
    id<MTLCommandBuffer> last = nil;
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (int f = 0; f < 60; f++) {
        for (int r = 0; r < 8; r++) {   // 8 x 64 MB reads ~ 2 ms on this class of GPU
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:p]; [e setBuffer:a offset:0 atIndex:0]; [e setBuffer:o offset:0 atIndex:1]; [e setBytes:&cnt length:4 atIndex:2];
            [e dispatchThreads:MTLSizeMake(65536, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; [e endEncoding]; [cb commit]; last = cb;
        }
        for (int u = 0; u < 20; u++) {
            for (int k = 0; k < 256; k++) tile[k] = (uint32_t)(f * 20 + u);
            [tex replaceRegion:MTLRegionMake2D((u % 32) * 16, (u / 32) * 16, 16, 16) mipmapLevel:0 withBytes:tile bytesPerRow:64];
        }
    }
    [last waitUntilCompleted];
    const double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
    printf("RESULT PASS 60 frames with 20 uploads each: %.1f ms total, %.2f ms per frame\n", ms, ms / 60);
    return 0;
}

// An upload left in flight while thousands of other submissions go by, then read back. The completion witness
// ring has 4096 slots; an upload finished after its slot was reused must not take the whole GPU backend down.
static int test_late_upload_finish(void) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    id<MTLTexture> tex = [dev newTextureWithDescriptor:d];
    static uint32_t px[64 * 64]; for (int i = 0; i < 64 * 64; i++) px[i] = 0xFF00FF00u;
    [tex replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:px bytesPerRow:256];
    id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = nil;
    for (int i = 0; i < 5000; i++) {
        cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl fillBuffer:b range:NSMakeRange(0, 4096) value:(uint8_t)i]; [bl endEncoding]; [cb commit];
        if (i % 64 == 63) [cb waitUntilCompleted];
    }
    [cb waitUntilCompleted];
    static uint32_t back[64 * 64];
    [tex getBytes:back bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
    id<MTLCommandBuffer> after = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [after blitCommandEncoder];
    [bl fillBuffer:b range:NSMakeRange(0, 4096) value:7]; [bl endEncoding]; [after commit]; [after waitUntilCompleted];
    if (after.status != MTLCommandBufferStatusCompleted) { printf("RESULT FAIL GPU backend went down after finishing a late upload (status %ld)\n", (long)after.status); return 1; }
    if (memcmp(back, px, sizeof px)) { printf("RESULT FAIL readback differs\n"); return 1; }
    printf("RESULT PASS upload finished after 5000 submissions; GPU still works\n");
    return 0;
}

// Minecraft-shaped startup: thousands of textures, each uploaded once and never touched again. Every pending async
// upload holds kernel connections (its recording pool and staging memory); the kext allows 4096 per process, so
// uploads that stay pending until the SAME texture is written again exhaust it and every later map fails.
static int test_many_textures(void) {
    enum { N = 3000, S = 16 };
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:S height:S mipmapped:NO];
    NSMutableArray *texs = [NSMutableArray arrayWithCapacity:N];
    static uint32_t px[S * S];
    for (int i = 0; i < N; i++) {
        id<MTLTexture> t = [dev newTextureWithDescriptor:d];
        if (!t) { printf("RESULT FAIL texture %d not created\n", i); return 1; }
        for (int k = 0; k < S * S; k++) px[k] = 0xFF000000u | (uint32_t)i;
        [t replaceRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0 withBytes:px bytesPerRow:S * 4];
        [texs addObject:t];
    }
    id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl fillBuffer:b range:NSMakeRange(0, 4096) value:9]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted || ((uint8_t *)b.contents)[100] != 9) {
        printf("RESULT FAIL GPU work after %d uploads did not run (status %ld)\n", N, (long)cb.status); return 1; }
    static uint32_t back[S * S];
    for (int i = 0; i < N; i += 499) {
        [texs[i] getBytes:back bytesPerRow:S * 4 fromRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0];
        if (back[0] != (0xFF000000u | (uint32_t)i) || back[S * S - 1] != back[0]) { printf("RESULT FAIL texture %d reads back 0x%08x\n", i, back[0]); return 1; }
    }
    printf("RESULT PASS %d textures uploaded once each; GPU still works and readbacks match\n", N);
    return 0;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) return 2;
    signal(SIGALRM, timeout_hit); alarm(40);
    if (!dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) { printf("RESULT FAIL load %s\n", dlerror()); return 3; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
    if (!svc) { printf("RESULT FAIL no NVAccel\n"); return 4; }
    dev = ((id(*)(id, SEL, mach_port_t))objc_msgSend)([NSClassFromString(@"NVMTLDevice") alloc], NSSelectorFromString(@"initWithAcceleratorPort:"), svc);
    IOObjectRelease(svc);
    if (!dev) { printf("RESULT FAIL no device\n"); return 5; }
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *t = argv[2];
    if (!strcmp(t, "compute")) return test_compute();
    if (!strcmp(t, "handler")) return test_handler_wait();
    if (!strcmp(t, "nocopy")) return test_nocopy_dealloc();
    if (!strcmp(t, "events")) return test_events();
    if (!strcmp(t, "bandwidth")) return test_bandwidth();
    if (!strcmp(t, "stress")) return test_stress();
    if (!strcmp(t, "texup")) return test_texture_uploads();
    if (!strcmp(t, "texbench")) return test_texture_upload_bench();
    if (!strcmp(t, "texlate")) return test_late_upload_finish();
    if (!strcmp(t, "texmany")) return test_many_textures();
    printf("RESULT FAIL unknown test\n"); return 2;
} }
