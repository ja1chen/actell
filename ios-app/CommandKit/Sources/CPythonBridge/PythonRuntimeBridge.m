#include <Python/Python.h>
#import "PythonRuntimeBridge.h"
#include <unistd.h>

@interface PythonRequest : NSObject
@property(nonatomic, copy) NSArray<NSString *> *arguments;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) BOOL (^cancelled)(void);
@property(nonatomic, strong) NSCondition *completion;
@property(nonatomic) int inputFD;
@property(nonatomic) int outputFD;
@property(nonatomic) int errorFD;
@property(nonatomic) int status;
@property(nonatomic) BOOL finished;
@end
@implementation PythonRequest
@end

// Used only on the interpreter thread, including the trace callback.
static PythonRequest *currentRequest;
static int cancellationTrace(PyObject *object, PyFrameObject *frame, int event, PyObject *argument) {
    if (currentRequest.cancelled()) {
        // Never raise between entering the bootstrap's finally block and its
        // first sys.settrace(None). Cleanup must restore streams even if the
        // deadline arrives exactly as user code returns.
        PyCodeObject *code = PyFrame_GetCode(frame);
        PyObject *filename = code ? PyObject_GetAttrString((PyObject *)code, "co_filename") : NULL;
        const char *name = filename ? PyUnicode_AsUTF8(filename) : NULL;
        BOOL bootstrap = name && strstr(name, "/actell_cli.py") != NULL;
        Py_XDECREF(filename); Py_XDECREF(code);
        if (bootstrap) return 0;
        PyErr_SetNone(PyExc_KeyboardInterrupt);
        return -1;
    }
    return 0;
}
static PyObject *checkCancellation(PyObject *self, PyObject *args) {
    if (currentRequest && currentRequest.cancelled()) {
        PyErr_SetNone(PyExc_KeyboardInterrupt);
        return NULL;
    }
    Py_RETURN_NONE;
}
static PyObject *enableTrace(PyObject *self, PyObject *args) {
    PyEval_SetTrace(cancellationTrace, NULL);
    Py_RETURN_NONE;
}
static PyMethodDef hostMethods[] = {
    {"check_cancelled", checkCancellation, METH_NOARGS, "Raise KeyboardInterrupt when the host requests cancellation."},
    {"enable_trace", enableTrace, METH_NOARGS, "Enable cooperative cancellation checks."},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef hostModule = {PyModuleDef_HEAD_INIT, "_actell_host", NULL, -1, hostMethods};
static PyObject *initializeHost(void) { return PyModule_Create(&hostModule); }

@implementation ActellPythonRuntime {
    NSCondition *_queue;
    NSMutableArray<PythonRequest *> *_requests;
    NSThread *_worker;
    PyThreadState *_threadState;
    NSString *_initializationError;
    BOOL _attemptedInitialization;
}
+ (instancetype)shared {
    static ActellPythonRuntime *runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ runtime = [ActellPythonRuntime new]; });
    return runtime;
}
- (instancetype)init {
    if ((self = [super init])) {
        _queue = [NSCondition new];
        _requests = [NSMutableArray new];
        _worker = [[NSThread alloc] initWithTarget:self selector:@selector(work) object:nil];
        _worker.name = @"Actell Python runtime";
        [_worker start];
    }
    return self;
}
- (BOOL)initializeInterpreter {
    if (_attemptedInitialization) return _initializationError == nil;
    _attemptedInitialization = YES;
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *home = [resources stringByAppendingPathComponent:@"python"];
    if (![NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"app/actell_cli.py"]]) {
        _initializationError = @"Bundled Python resources are missing. Rebuild after preparing the runtime.";
        return NO;
    }
    if (PyImport_AppendInittab("_actell_host", initializeHost) != 0) {
        _initializationError = @"Cannot register Python host module.";
        return NO;
    }
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&pre);
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0;
    config.module_search_paths_set = 1;
    if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
    if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.program_name, "python3");
    for (NSString *relative in @[@"python/lib/python3.13", @"python/lib/python3.13/lib-dynload", @"python/site-packages", @"python/app"]) {
        if (PyStatus_Exception(status)) break;
        wchar_t *path = Py_DecodeLocale([resources stringByAppendingPathComponent:relative].UTF8String, NULL);
        if (!path) { status = PyStatus_Error("Python path decoding failed"); break; }
        status = PyWideStringList_Append(&config.module_search_paths, path);
        PyMem_RawFree(path);
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        _initializationError = [NSString stringWithUTF8String:status.err_msg ?: "Python initialization failed"];
        return NO;
    }
    return YES;
}
- (void)work {
    while (YES) {
        @autoreleasepool {
            [_queue lock];
            while (!_requests.count) [_queue wait];
            PythonRequest *request = _requests.firstObject;
            [_requests removeObjectAtIndex:0];
            [_queue unlock];
            if (_threadState) { PyEval_RestoreThread(_threadState); _threadState = NULL; }
            if ([self initializeInterpreter]) {
                currentRequest = request;
                PyObject *module = PyImport_ImportModule("actell_cli");
                PyObject *function = module ? PyObject_GetAttrString(module, "run") : NULL;
                PyObject *argv = PyList_New((Py_ssize_t)request.arguments.count);
                BOOL argumentsReady = argv != NULL;
                for (NSUInteger i = 0; argumentsReady && i < request.arguments.count; i++) {
                    PyObject *value = PyUnicode_FromString(request.arguments[i].UTF8String);
                    if (!value) { argumentsReady = NO; break; }
                    PyList_SET_ITEM(argv, i, value);
                }
                PyObject *args = argumentsReady ? Py_BuildValue("Oiiis", argv, request.inputFD, request.outputFD,
                                                              request.errorFD, request.directory.UTF8String) : NULL;
                // The bootstrap installs streams before enabling the trace so
                // cancellation/traceback diagnostics use this command's streams.
                PyObject *result = function && args ? PyObject_CallObject(function, args) : NULL;
                if (result) {
                    long status = PyLong_AsLong(result);
                    request.status = PyErr_Occurred() ? 1 : (int)status;
                } else {
                    dprintf(request.errorFD, "Python runtime failed to execute the command.\n");
                    PyErr_Clear();
                    request.status = 1;
                }
                Py_XDECREF(result); Py_XDECREF(args); Py_XDECREF(argv); Py_XDECREF(function); Py_XDECREF(module);
                PyEval_SetTrace(NULL, NULL);
                currentRequest = nil;
                _threadState = PyEval_SaveThread();
            } else {
                dprintf(request.errorFD, "%s\n", _initializationError.UTF8String);
                request.status = 1;
            }
            close(request.inputFD); close(request.outputFD); close(request.errorFD);
            [request.completion lock]; request.finished = YES;
            [request.completion broadcast]; [request.completion unlock];
        }
    }
}
- (int)runArguments:(NSArray<NSString *> *)arguments input:(FILE *)input output:(FILE *)output error:(FILE *)error
          directory:(NSString *)directory cancelled:(BOOL (^)(void))cancelled {
    PythonRequest *request = [PythonRequest new];
    request.arguments = arguments; request.directory = directory; request.cancelled = cancelled;
    request.completion = [NSCondition new];
    request.inputFD = dup(fileno(input)); request.outputFD = dup(fileno(output)); request.errorFD = dup(fileno(error));
    if (request.inputFD < 0 || request.outputFD < 0 || request.errorFD < 0) {
        if (request.inputFD >= 0) close(request.inputFD);
        if (request.outputFD >= 0) close(request.outputFD);
        if (request.errorFD >= 0) close(request.errorFD);
        return 1;
    }
    [_queue lock]; [_requests addObject:request]; [_queue signal]; [_queue unlock];
    [request.completion lock];
    while (!request.finished) [request.completion wait];
    [request.completion unlock];
    return request.status;
}
@end
