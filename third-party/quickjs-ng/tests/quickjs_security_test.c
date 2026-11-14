// Benign engine regressions. No widget delivery, native payload or external I/O.
// Fixtures are from TelegramMessenger/quickjs b526a817 (see VENDOR.md).
#include "quickjs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;
static const char *fixture_root;
static double deadline;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static int interrupt(JSRuntime *rt, void *opaque) {
    (void)rt; (void)opaque;
    return now() > deadline;
}

static char *read_fixture(const char *name, size_t *size) {
    char path[4096];
    if (snprintf(path, sizeof(path), "%s/%s", fixture_root, name) >= sizeof(path)) return NULL;
    FILE *file = fopen(path, "rb");
    if (!file) { perror(path); return NULL; }
    if (fseek(file, 0, SEEK_END) || (*size = (size_t)ftell(file)) > 100000 || fseek(file, 0, SEEK_SET)) {
        fclose(file); return NULL;
    }
    char *source = malloc(*size + 1);
    if (!source) { fclose(file); return NULL; }
    if (fread(source, 1, *size, file) != *size) { free(source); fclose(file); return NULL; }
    fclose(file);
    source[*size] = 0;
    return source;
}

static JSModuleDef *load_assert(JSContext *ctx, const char *name, void *opaque) {
    (void)opaque;
    if (strcmp(name, "assert.js")) { JS_ThrowReferenceError(ctx, "unexpected test module"); return NULL; }
    size_t size;
    char *source = read_fixture("assert.js", &size);
    if (!source) { JS_ThrowInternalError(ctx, "missing assert fixture"); return NULL; }
    JSValue value = JS_Eval(ctx, source, size, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(source);
    if (JS_IsException(value)) return NULL;
    JSModuleDef *module = JS_VALUE_GET_PTR(value);
    JS_FreeValue(ctx, value);
    return module;
}

static void describe_exception(JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
    const char *text = JS_ToCString(ctx, error);
    fprintf(stderr, "exception: %s\n", text ? text : "<unavailable>");
    JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, error);
}

static void run_fixture(JSContext *ctx, const char *name) {
    size_t size;
    char *source = read_fixture(name, &size);
    CHECK(source != NULL);
    if (!source) return;
    JSValue result = JS_Eval(ctx, source, size, name, JS_EVAL_TYPE_MODULE);
    free(source);
    CHECK(!JS_IsException(result));
    if (JS_IsException(result)) describe_exception(ctx);
    JSContext *job_ctx;
    int job, count = 0;
    while ((job = JS_ExecutePendingJob(JS_GetRuntime(ctx), &job_ctx)) > 0 && ++count < 1000) {}
    CHECK(job == 0);
    if (job < 0) describe_exception(job_ctx);
    if (JS_IsObject(result) && JS_PromiseState(ctx, result) == JS_PROMISE_REJECTED) {
        JSValue reason = JS_PromiseResult(ctx, result);
        JS_Throw(ctx, reason);
        describe_exception(ctx);
        CHECK(0);
    }
    JS_FreeValue(ctx, result);
}

static void compiles(JSContext *ctx, const char *source, int type, int expected) {
    JSValue result = JS_Eval(ctx, source, strlen(source), "<await-using>", type | JS_EVAL_FLAG_COMPILE_ONLY);
    CHECK(!JS_IsException(result) == expected);
    if (JS_IsException(result)) {
        JSValue error = JS_GetException(ctx);
        const char *text = JS_ToCString(ctx, error);
        CHECK(text && strstr(text, "SyntaxError"));
        JS_FreeCString(ctx, text);
        JS_FreeValue(ctx, error);
    }
    JS_FreeValue(ctx, result);
}

static void await_using(JSContext *ctx) {
    int script = JS_EVAL_TYPE_GLOBAL, module = JS_EVAL_TYPE_MODULE;
    compiles(ctx, "class C { static { for (await using x of []) {} } }", script, 0);
    compiles(ctx, "class C { static { for (await using x in {}) {} } }", script, 0);
    compiles(ctx, "function f() { for (await using x of []) {} }", module, 0);
    compiles(ctx, "class C { static { for (await using x of []) {} } }", module, 0);
    compiles(ctx, "export function f() { for (await using [a] of []) {} }", module, 0);
    compiles(ctx, "async function f() { for (await using x of []) {} }", script, 1);
    compiles(ctx, "(async () => { for (await using x of []) {} })", script, 1);
    compiles(ctx, "async function* g() { for (await using x of []) {} }", script, 1);
    compiles(ctx, "for (await using x of []) {}", module, 1);
    compiles(ctx, "function f() { for (using x of []) {} }", script, 1);
}

static void argument_scope(JSContext *ctx) {
    const char *source =
        "'use strict';"
        "function f([] = eval('1')) {}"
        "var caught = false; try { f(); } catch(e) { if (!(e instanceof TypeError)) throw e; caught = true; }"
        "if (!caught) throw Error('destructuring a number must throw TypeError');"
        "function g([] = eval('[]')) { return 42; }"
        "if (g() !== 42) throw Error('valid empty destructuring');"
        "function h({} = eval(...['({})'])) { return 43; }"
        "if (h() !== 43) throw Error('spread eval in empty argument scope');"
        "var arrow = ([] = eval('[]')) => 44;"
        "if (arrow() !== 44) throw Error('arrow argument environment');"
        "function named(a = 45, [] = eval('[]'), b = eval('a')) { return b; }"
        "if (named() !== 45) throw Error('named parameter must remain visible');"
        "function scope([] = eval('[]'), read = () => eval('typeof bodyOnly')) { var bodyOnly = 1; return read(); }"
        "if (scope() !== 'undefined') throw Error('body locals leaked into argument environment');";
    JSValue result = JS_Eval(ctx, source, strlen(source), "<argument-scope>", JS_EVAL_TYPE_GLOBAL);
    CHECK(!JS_IsException(result));
    if (JS_IsException(result)) describe_exception(ctx);
    JS_FreeValue(ctx, result);

    // Cache round trips must retain the new signed scope operand. Older blobs
    // must fail at their version header before any old instruction is decoded.
    JSValue compiled = JS_Eval(ctx, source, strlen(source), "<argument-scope-cache>", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    CHECK(!JS_IsException(compiled));
    if (!JS_IsException(compiled)) {
        size_t size = 0;
        uint8_t *bytes = JS_WriteObject(ctx, &size, compiled, JS_WRITE_OBJ_BYTECODE);
        CHECK(bytes && size > 1);
        if (bytes && size > 1) {
            JSValue loaded = JS_ReadObject(ctx, bytes, size, JS_READ_OBJ_BYTECODE);
            CHECK(!JS_IsException(loaded));
            if (!JS_IsException(loaded)) {
                JSValue evaluated = JS_EvalFunction(ctx, loaded);
                CHECK(!JS_IsException(evaluated));
                if (JS_IsException(evaluated)) describe_exception(ctx);
                JS_FreeValue(ctx, evaluated);
            } else describe_exception(ctx);
            bytes[0]--;
            JSValue stale = JS_ReadObject(ctx, bytes, size, JS_READ_OBJ_BYTECODE);
            CHECK(JS_IsException(stale));
            if (JS_IsException(stale)) JS_FreeValue(ctx, JS_GetException(ctx));
            JS_FreeValue(ctx, stale);
            js_free(ctx, bytes);
        }
    } else describe_exception(ctx);
    JS_FreeValue(ctx, compiled);
}

int main(int argc, char **argv) {
    const char *files[] = {
        "direct-eval-closure-var-overflow.js", "mapped-arguments-var-ref-overflow.js",
        "map-clear-iterator-value-uaf.js", "finalizationregistry-unregister-held-target.js",
        "weakref-weakmap-value-same-target.js", "regexp-delete-lastindex-order.js",
        "await-using", "argument-scope"
    };
    char runfiles_root[4096];
    fixture_root = getenv("QUICKJS_SECURITY_FIXTURES");
    if (!fixture_root) {
        const char *runfiles = getenv("TEST_SRCDIR"), *workspace = getenv("TEST_WORKSPACE");
        if (runfiles && workspace) {
            snprintf(runfiles_root, sizeof(runfiles_root), "%s/%s/third-party/quickjs-ng/tests/security", runfiles, workspace);
            fixture_root = runfiles_root;
        } else fixture_root = "third-party/quickjs-ng/tests/security";
    }
    int selected = 0;
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        if (argc > 1 && strcmp(files[i], argv[1])) continue;
        selected++;
        printf("RUN %s\n", files[i]); fflush(stdout);
        JSRuntime *rt = JS_NewRuntime();
        CHECK(rt != NULL);
        if (!rt) continue;
        JS_SetMemoryLimit(rt, 128u << 20);
        JS_SetMaxStackSize(rt, 2u << 20);
        JS_SetModuleLoaderFunc(rt, NULL, load_assert, NULL);
        deadline = now() + 10;
        JS_SetInterruptHandler(rt, interrupt, NULL);
        JSContext *ctx = JS_NewContext(rt);
        CHECK(ctx != NULL);
        if (ctx) {
            if (!strcmp(files[i], "await-using")) await_using(ctx);
            else if (!strcmp(files[i], "argument-scope")) argument_scope(ctx);
            else run_fixture(ctx, files[i]);
            JS_FreeContext(ctx);
        }
        JS_RunGC(rt);
        JS_FreeRuntime(rt);
    }
    CHECK(selected > 0);
    printf("quickjs security: %d cases, %d failures\n", selected, failures);
    return failures ? 1 : 0;
}
