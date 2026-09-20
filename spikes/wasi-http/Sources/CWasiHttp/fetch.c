#include "probe.h"
#include "escriba_http.h"

void __component_type_object_force_link_probe(void) {}

int32_t escriba_fetch_status(const char *authority, const char *path) {
    wasi_http_types_own_fields_t headers = wasi_http_types_constructor_fields();
    wasi_http_types_own_outgoing_request_t request = wasi_http_types_constructor_outgoing_request(headers);
    wasi_http_types_borrow_outgoing_request_t req = wasi_http_types_borrow_outgoing_request(request);

    wasi_http_types_method_t method = { .tag = WASI_HTTP_TYPES_METHOD_GET };
    if (!wasi_http_types_method_outgoing_request_set_method(req, &method)) return -10;
    wasi_http_types_scheme_t scheme = { .tag = WASI_HTTP_TYPES_SCHEME_HTTPS };
    if (!wasi_http_types_method_outgoing_request_set_scheme(req, &scheme)) return -11;
    probe_string_t auth; probe_string_set(&auth, authority);
    if (!wasi_http_types_method_outgoing_request_set_authority(req, &auth)) return -12;
    probe_string_t p; probe_string_set(&p, path);
    if (!wasi_http_types_method_outgoing_request_set_path_with_query(req, &p)) return -13;

    wasi_http_outgoing_handler_own_future_incoming_response_t future;
    wasi_http_outgoing_handler_error_code_t err;
    if (!wasi_http_outgoing_handler_handle(request, NULL, &future, &err)) return -1;

    wasi_http_types_borrow_future_incoming_response_t fut = wasi_http_types_borrow_future_incoming_response(future);
    wasi_io_poll_own_pollable_t pollable = wasi_http_types_method_future_incoming_response_subscribe(fut);
    wasi_io_poll_method_pollable_block(wasi_io_poll_borrow_pollable(pollable));

    wasi_http_types_result_result_own_incoming_response_error_code_void_t result;
    if (!wasi_http_types_method_future_incoming_response_get(fut, &result)) return -2;
    if (result.is_err) return -3;
    if (result.val.ok.is_err) return -4;
    wasi_http_types_own_incoming_response_t response = result.val.ok.val.ok;
    return (int32_t)wasi_http_types_method_incoming_response_status(wasi_http_types_borrow_incoming_response(response));
}
