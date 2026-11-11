#!/usr/bin/env python3
"""Build the optional VLC3.0.24 arm64 compatibility plugins from pinned sources.

Uses a pinned official VLC.app reference, read only. Never installs plugins.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import urllib.request
from reference import obtain as obtain_reference, verify_app as verify_reference

HERE=Path(__file__).resolve().parent

def sha(p):
    h=hashlib.sha256()
    with p.open('rb')as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def checked(command,cwd,log,env=None):
    with log.open('w')as f:
        result=subprocess.run(command,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,env=env)
    if result.returncode:raise RuntimeError(f'Command failed; see {log}')

def unpack(archive,destination):
    with tarfile.open(archive)as t:
        members=t.getmembers();roots={m.name.split('/')[0]for m in members}
        if len(roots)!=1:raise ValueError('Source archive must have one root')
        for m in members:
            path=Path(m.name)
            if path.is_absolute()or '..'in path.parts or m.isdev():raise ValueError('Unsafe archive path')
            if m.issym()or m.islnk():
                target=Path(m.linkname)
                if target.is_absolute()or '..'in target.parts:raise ValueError('Unsafe source archive link')
        t.extractall(destination)
    return destination/next(iter(roots))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--vlc-app',type=Path);p.add_argument('--archives',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--fetch',action='store_true')
    p.add_argument('--prepare-only',action='store_true');p.add_argument('--jobs',type=int,default=4)
    a=p.parse_args();out=a.output.resolve();archives=a.archives.resolve()
    if out.exists():raise SystemExit('Output must be a new directory')
    if not 1<=a.jobs<=16:raise SystemExit('jobs must be1..16')
    app=a.vlc_app.resolve() if a.vlc_app else obtain_reference(archives,a.fetch)
    reference_lock=json.loads((HERE/'reference.lock.json').read_text())
    verify_reference(app,reference_lock)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString')!='3.0.24' or info.get('CFBundleIdentifier')!='org.videolan.vlc':raise SystemExit('Official VLC3.0.24 reference required')
    if subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/VLC')],text=True).strip()!='arm64':raise SystemExit('Thin arm64 VLC reference required')
    out.mkdir(parents=True);archives.mkdir(parents=True,exist_ok=True);logs=out/'logs';logs.mkdir();sources=out/'sources';sources.mkdir()
    lock=json.loads((HERE/'inputs.lock.json').read_text());trees={}
    for name,item in lock['archives'].items():
        path=archives/name
        if not path.exists():
            if not a.fetch:raise SystemExit(f'Missing {name}; supply archive or use --fetch')
            temp=path.with_suffix(path.suffix+'.partial')
            with urllib.request.urlopen(item['url'],timeout=60)as response,temp.open('wb')as f:shutil.copyfileobj(response,f)
            if sha(temp)!=item['sha256']:temp.unlink();raise ValueError(f'Checksum mismatch: {name}')
            temp.replace(path)
        if sha(path)!=item['sha256']:raise ValueError(f'Checksum mismatch: {name}')
        trees[name]=unpack(path,sources)
    vlc=trees['vlc-3.0.24.tar.gz'];ff=trees['ffmpeg-8.1.2.tar.xz'];x265=trees['x265_4.1.tar.gz'];src=trees['libsamplerate-0.1.9.tar.gz']
    for name in(HERE/'patches/series').read_text().splitlines():checked(['patch','-p1','--batch','--forward','-i',str(HERE/'patches'/name)],vlc,logs/(name+'.log'))
    for directory,name in [(src,'libsamplerate-constant-rate-eof.patch'),(x265,'x265-macos-cmake.patch')]:checked(['patch','-p1','--batch','--forward','-i',str(HERE/'patches'/name)],directory,logs/(name+'.log'))
    provenance=json.loads((HERE/'source-provenance.json').read_text())
    for name,ident in provenance['changed_sources'].items():
        if sha(vlc/name)!=ident['after_sha256']:raise ValueError(f'Patched source mismatch: {name}')
    receipt={'source_lock':lock,'patched_sources':provenance,'reference_app_version':'3.0.24','reference_core_sha256':sha(app/'Contents/MacOS/lib/libvlccore.dylib'),'reference_provenance':{'mode':'explicit-readonly'if a.vlc_app else'pinned-automatic','lock_sha256':sha(HERE/'reference.lock.json'),'official_signature_verified':True},'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),'minimum_macos':'14.0','state':'prepared; not installed'}
    (out/'build-receipt.json').write_text(json.dumps(receipt,indent=2))
    if a.prepare_only:return
    prefix=f'-ffile-prefix-map={out}=.'
    source_prefix=f'-ffile-prefix-map={HERE}=compat/vlc'
    flags=f'-O2 -mmacosx-version-min=14.0 -fvisibility=hidden {prefix} {source_prefix}'
    configure=['./configure','--cc=clang','--arch=aarch64','--target-os=darwin','--disable-everything','--disable-autodetect','--disable-network','--disable-doc','--disable-debug','--disable-shared','--enable-static','--enable-pic','--disable-programs','--disable-avdevice','--disable-avfilter','--disable-swscale','--disable-swresample','--disable-iconv','--disable-videotoolbox','--disable-audiotoolbox','--disable-securetransport','--enable-avformat','--enable-protocol=file','--enable-demuxer=mov','--enable-parser=aac,h264,hevc','--enable-encoder=aac','--enable-decoder=aac','--extra-cflags='+flags,'--extra-ldflags=-mmacosx-version-min=14.0']
    checked(configure,ff,logs/'ffmpeg-configure.log')
    # FFmpeg also embeds the configure command as a runtime information string.
    # Normalize paths in that string only; real compilation still uses its maps.
    config=ff/'config.h';lines=config.read_text().splitlines(keepends=True)
    matches=[i for i,line in enumerate(lines)if line.startswith('#define FFMPEG_CONFIGURATION ')]
    if len(matches)!=1:raise ValueError('Missing FFmpeg runtime configuration declaration')
    i=matches[0];lines[i]=lines[i].replace(str(out),'.').replace(str(HERE),'compat/vlc')
    config.write_text(''.join(lines))
    checked(['make','-j',str(a.jobs)],ff,logs/'ffmpeg-build.log')
    xb=out/'x265-build'
    checked(['cmake','-S',str(x265/'source'),'-B',str(xb),'-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0','-DENABLE_SHARED=OFF','-DENABLE_CLI=OFF','-DENABLE_ASSEMBLY=OFF','-DCMAKE_C_FLAGS='+prefix+' '+source_prefix,'-DCMAKE_CXX_FLAGS='+prefix+' '+source_prefix],out,logs/'x265-configure.log')
    checked(['cmake','--build',str(xb),'--parallel',str(a.jobs)],out,logs/'x265-build.log')
    env=os.environ.copy();env['CFLAGS']=flags;env['LDFLAGS']='-mmacosx-version-min=14.0'
    checked(['./configure','--disable-shared','--enable-static','--disable-fftw','--disable-sndfile'],src,logs/'samplerate-configure.log',env);checked(['make','-j',str(a.jobs)],src,logs/'samplerate-build.log',env)
    plugins=out/'plugins';plugins.mkdir();obj=out/'objects';obj.mkdir();encoder=out/'encoder';encoder.mkdir();support=HERE/'support';core=app/'Contents/MacOS/lib'
    for name in ['encoder.c','fourcc.c','chroma.c','chroma.h','avcodec.h','avcommon.h','avcommon_compat.h']:shutil.copy(vlc/'modules/codec/avcodec'/name,encoder/name)
    path=encoder/'avcodec.h';path.write_text(path.read_text().replace('sout-aacfix-','sout-aacgap-'))
    common=['clang','-c','-O2','-fvisibility=hidden','-mmacosx-version-min=14.0',prefix,source_prefix,'-D__PLUGIN__','-DENABLE_SOUT','-DHAVE_LIBAVFORMAT_AVFORMAT_H','-DHAVE_LIBAVCODEC_AVCODEC_H','-DHAVE_LIBAVUTIL_AVUTIL_H','-DHAVE_LIBAVUTIL_CHANNEL_LAYOUT_H','-DPACKAGE_STRING="VLC 3.0.24 compatibility"','-I'+str(vlc/'include'),'-I'+str(ff),'-I'+str(encoder),'-I'+str(vlc/'modules/mux'),'-include',str(support/'config_local.h')]
    ff_libs=[str(ff/x)for x in ['libavformat/libavformat.a','libavcodec/libavcodec.a','libavutil/libavutil.a']]
    (obj/'demux_module.c').write_text('''#include <vlc_common.h>
#include <vlc_plugin.h>
int avformat_OpenDemux(vlc_object_t*);void avformat_CloseDemux(vlc_object_t*);
vlc_module_begin()
set_description("Gapless AAC metadata demux")
set_capability("demux",400)
add_shortcut("avgap", "mp4", "m4a", "mov")
set_callbacks(avformat_OpenDemux,avformat_CloseDemux)
vlc_module_end()
''')
    (obj/'decoder_module.c').write_text('''#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_codec.h>
int InitAudioDec(vlc_object_t*);void EndAudioDec(vlc_object_t*);
static int Open(vlc_object_t*o){decoder_t*d=(decoder_t*)o;if(d->fmt_in.i_cat!=AUDIO_ES||d->fmt_in.i_codec!=VLC_CODEC_MP4A||d->fmt_in.audio_gapless.magic!=VLC_AUDIO_GAPLESS_MAGIC)return VLC_EGENERIC;return InitAudioDec(o);}
vlc_module_begin()
set_description("Gapless AAC decoder")
set_capability("audio decoder",500)
add_shortcut("aacdecgap", "avcodec")
set_callbacks(Open,EndAudioDec)
vlc_module_end()
''')
    def build(name,files,libs=(),extra=(),cxx=False):
        objects=[]
        for index,file in enumerate(files):
            target=obj/f'{name}-{index}.o';objects.append(str(target));checked(common+list(extra)+['-DMODULE_STRING="'+name+'"',str(file),'-o',str(target)],out,logs/f'{name}-{index}.log')
        checked(['clang++'if cxx else'clang','-dynamiclib','-mmacosx-version-min=14.0','-Wl,-reproducible','-install_name',f'@rpath/lib{name}_plugin.dylib','-o',str(plugins/f'lib{name}_plugin.dylib')]+objects+list(libs)+['-L'+str(core),'-lvlccore','-framework','CoreFoundation','-framework','CoreVideo','-framework','CoreMedia','-Wl,-exported_symbols_list,'+str(support/'exports.txt')],out,logs/f'{name}-link.log')
    build('aacgap',[encoder/'encoder.c',support/'module.c',encoder/'fourcc.c',encoder/'chroma.c',support/'audio_format.c'],ff_libs)
    build('avgap',[obj/'demux_module.c',vlc/'modules/demux/avformat/demux.c',encoder/'fourcc.c',encoder/'chroma.c'],ff_libs)
    build('aacdecgap',[obj/'decoder_module.c',vlc/'modules/codec/avcodec/audio.c',vlc/'modules/codec/avcodec/helpers.c',encoder/'fourcc.c',encoder/'chroma.c'],ff_libs)
    build('aacpacketgap',[vlc/'modules/packetizer/mpeg4audio.c'])
    build('stream_out_transcode',[vlc/f'modules/stream_out/transcode/{name}.c'for name in ['transcode','audio','video','spu']])
    build('mux_mp4',[vlc/f'modules/mux/mp4/{name}.c'for name in ['mp4','libmp4mux']]+[vlc/f'modules/packetizer/{name}.c'for name in ['hxxx_nal','h264_nal','hevc_nal']])
    build('samplerate',[vlc/'modules/audio_filter/resampler/src.c'],[str(src/'src/.libs/libsamplerate.a')],['-I'+str(src/'src')])
    build('x265',[vlc/'modules/codec/x265.c'],[str(xb/'libx265.a')],['-I'+str(x265/'source'),'-I'+str(xb),'-DNDEBUG'],True)
    gui_flags=['clang','-c','-O2','-fobjc-exceptions','-fobjc-arc','-fvisibility=hidden','-mmacosx-version-min=14.0',prefix,source_prefix,'-D__PLUGIN__','-DMODULE_STRING="macosx"','-I'+str(support),'-I'+str(vlc/'include'),'-I'+str(vlc/'src'),'-I'+str(vlc/'modules/gui/macosx'),'-F'+str(app/'Contents/Frameworks'),'-include',str(support/'gui_config.h'),'-Wno-deprecated-declarations']
    files=sorted((vlc/'modules/gui/macosx').rglob('*.m'))
    def gui(file):
        target=obj/('gui-'+str(file.relative_to(vlc/'modules/gui/macosx')).replace('/','_')+'.o');checked(gui_flags+[str(file),'-o',str(target)],out,logs/(target.name+'.log'));return str(target)
    with ThreadPoolExecutor(max_workers=a.jobs)as pool:objects=list(pool.map(gui,files))
    command=['clang','-dynamiclib','-mmacosx-version-min=14.0','-Wl,-reproducible','-fobjc-arc','-o',str(plugins/'libmacosx_plugin.dylib')]+objects+['-L'+str(core),'-lvlccore','-F'+str(app/'Contents/Frameworks'),'-Wl,-install_name,@rpath/libmacosx_plugin.dylib']
    for f in ['Cocoa','CoreServices','AVFoundation','CoreMedia','IOKit','AddressBook','WebKit','CoreAudio','SystemConfiguration','ScriptingBridge','QuartzCore','MediaPlayer','Sparkle']:command+=['-framework',f]
    checked(command,out,logs/'gui-link.log')
    receipt.update(state='built; not installed',plugins={p.name:sha(p)for p in sorted(plugins.glob('*.dylib'))},gui_sources=len(files))
    (out/'build-receipt.json').write_text(json.dumps(receipt,indent=2));print(plugins)
if __name__=='__main__':main()
