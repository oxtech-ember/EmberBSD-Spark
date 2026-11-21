/* Count the production host's explicit libcurl acquisitions and releases. */
#undef curl_global_init
#undef curl_global_cleanup
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>

CURLcode test_curl_init(long flags) {
    static unsigned int attempts;
    fputs("curl init\n", stderr);
    if (++attempts == 1 && getenv("SPARK_TEST_FAIL_FIRST_CURL_INIT"))
        return CURLE_FAILED_INIT;
    return curl_global_init(flags);
}

void test_curl_cleanup(void) {
    fputs("curl cleanup\n", stderr);
    curl_global_cleanup();
}
