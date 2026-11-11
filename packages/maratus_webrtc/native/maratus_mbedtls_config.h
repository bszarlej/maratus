/* Additions to the default Mbed TLS 3.6 configuration. libdatachannel's DTLS
   transport configures DTLS-SRTP profiles even without media support. */
#define MBEDTLS_SSL_DTLS_SRTP
