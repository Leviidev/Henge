#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_codec.h>
#include <libavcodec/avcodec.h>
#include "avcodec.h"
static const char *const enc_hq_list[] = { "rd", "bits", "simple" };
static const char *const enc_hq_list_text[] = { "rd", "bits", "simple" };
static int Open(vlc_object_t*o){encoder_t*e=(encoder_t*)o;if(e->fmt_in.i_cat!=AUDIO_ES||e->fmt_out.i_codec!=VLC_CODEC_MP4A)return VLC_EGENERIC;return InitVideoEnc(o);}
vlc_module_begin()
 set_description("AAC source-patched encoder audit")
 set_capability("encoder",200)
 add_shortcut("aacgap", "avcodec")
 set_callbacks(Open,EndVideoEnc)
    add_string( ENC_CFG_PREFIX "codec", NULL, CODEC_TEXT, CODEC_LONGTEXT, true )
    add_string( ENC_CFG_PREFIX "hq", "rd", ENC_HQ_TEXT,
                ENC_HQ_LONGTEXT, false )
        change_string_list( enc_hq_list, enc_hq_list_text )
    add_integer( ENC_CFG_PREFIX "keyint", 0, ENC_KEYINT_TEXT,
                 ENC_KEYINT_LONGTEXT, false )
    add_integer( ENC_CFG_PREFIX "bframes", 0, ENC_BFRAMES_TEXT,
                 ENC_BFRAMES_LONGTEXT, false )
    add_bool( ENC_CFG_PREFIX "hurry-up", false, ENC_HURRYUP_TEXT,
              ENC_HURRYUP_LONGTEXT, false )
    add_bool( ENC_CFG_PREFIX "interlace", false, ENC_INTERLACE_TEXT,
              ENC_INTERLACE_LONGTEXT, true )
    add_bool( ENC_CFG_PREFIX "interlace-me", true, ENC_INTERLACE_ME_TEXT,
              ENC_INTERLACE_ME_LONGTEXT, true )
    add_integer( ENC_CFG_PREFIX "vt", 0, ENC_VT_TEXT,
                 ENC_VT_LONGTEXT, true )
    add_bool( ENC_CFG_PREFIX "pre-me", false, ENC_PRE_ME_TEXT,
              ENC_PRE_ME_LONGTEXT, true )
    add_integer( ENC_CFG_PREFIX "rc-buffer-size", 0,
                 ENC_RC_BUF_TEXT, ENC_RC_BUF_LONGTEXT, true )
    add_float( ENC_CFG_PREFIX "rc-buffer-aggressivity", 1.0,
               ENC_RC_BUF_AGGR_TEXT, ENC_RC_BUF_AGGR_LONGTEXT, true )
    add_float( ENC_CFG_PREFIX "i-quant-factor", 0,
               ENC_IQUANT_FACTOR_TEXT, ENC_IQUANT_FACTOR_LONGTEXT, true )
    add_integer( ENC_CFG_PREFIX "noise-reduction", 0,
                 ENC_NOISE_RED_TEXT, ENC_NOISE_RED_LONGTEXT, true )
    add_bool( ENC_CFG_PREFIX "mpeg4-matrix", false,
              ENC_MPEG4_MATRIX_TEXT, ENC_MPEG4_MATRIX_LONGTEXT, true )
    add_integer( ENC_CFG_PREFIX "qmin", 0,
                 ENC_QMIN_TEXT, ENC_QMIN_LONGTEXT, true )
    add_integer( ENC_CFG_PREFIX "qmax", 0,
                 ENC_QMAX_TEXT, ENC_QMAX_LONGTEXT, true )
    add_bool( ENC_CFG_PREFIX "trellis", false,
              ENC_TRELLIS_TEXT, ENC_TRELLIS_LONGTEXT, true )
    add_float( ENC_CFG_PREFIX "qscale", 3,
               ENC_QSCALE_TEXT, ENC_QSCALE_LONGTEXT, true )
    add_integer( ENC_CFG_PREFIX "strict", 0,
                 ENC_STRICT_TEXT, ENC_STRICT_LONGTEXT, true )
        change_integer_range( -2, 2 )
    add_float( ENC_CFG_PREFIX "lumi-masking", 0.0,
               ENC_LUMI_MASKING_TEXT, ENC_LUMI_MASKING_LONGTEXT, true )
    add_float( ENC_CFG_PREFIX "dark-masking", 0.0,
               ENC_DARK_MASKING_TEXT, ENC_DARK_MASKING_LONGTEXT, true )
    add_float( ENC_CFG_PREFIX "p-masking", 0.0,
               ENC_P_MASKING_TEXT, ENC_P_MASKING_LONGTEXT, true )
    add_float( ENC_CFG_PREFIX "border-masking", 0.0,
               ENC_BORDER_MASKING_TEXT, ENC_BORDER_MASKING_LONGTEXT, true )
    add_integer( ENC_CFG_PREFIX "luma-elim-threshold", 0,
                 ENC_LUMA_ELIM_TEXT, ENC_LUMA_ELIM_LONGTEXT, true )
    add_integer( ENC_CFG_PREFIX "chroma-elim-threshold", 0,
                 ENC_CHROMA_ELIM_TEXT, ENC_CHROMA_ELIM_LONGTEXT, true )

    /* Audio AAC encoder profile */
    add_string( ENC_CFG_PREFIX "aac-profile", "low",
                ENC_PROFILE_TEXT, ENC_PROFILE_LONGTEXT, true )

    add_string( ENC_CFG_PREFIX "options", NULL, AV_OPTIONS_TEXT, AV_OPTIONS_LONGTEXT, true )
vlc_module_end()
