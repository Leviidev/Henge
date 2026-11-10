#include <vlc_common.h>
#include <libavformat/version.h>
#define N_(text) (text)
#define _(text) vlc_gettext(text)

#include <stddef.h>
#include <vlc_codec.h>
_Static_assert(sizeof(es_format_t)==264,"es_format ABI");
_Static_assert(sizeof(encoder_t)==632,"encoder ABI");
_Static_assert(sizeof(decoder_t)==744,"decoder ABI");
_Static_assert(offsetof(es_format_t,i_bitrate)==232,"format union ABI");
_Static_assert(offsetof(encoder_t,pf_encode_audio)==592,"encoder callbacks ABI");
