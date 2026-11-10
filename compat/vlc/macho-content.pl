#!/usr/bin/perl
# Hash all signed Mach-O content, normalizing only signature metadata.
# ARM64 thin Mach-O only, matching the task's VLC3.0.24 app.
use strict;use warnings;use Digest::SHA qw(sha256_hex);
my$file=shift or die "Usage: macho-content.pl ARM64_EXECUTABLE\n";
open my$f,'<:raw',$file or die$!;local$/;my$data=<$f>;close$f;
my($magic,$cpu,$sub,$type,$ncmd,$szcmd)=unpack('V6',substr($data,0,24));
die "Expected thin arm64 Mach-O\n" unless $magic==0xfeedfacf&&$cpu==0x0100000c;
die "Bad command bounds\n" if 32+$szcmd>length$data;
my$normalized=$data;my$at=32;my$sigoff;my@loads;
for(1..$ncmd){
 my($cmd,$sz)=unpack('V2',substr($data,$at,8));die "Bad command size\n" if$sz<8||$at+$sz>32+$szcmd;
 if($cmd==0x1d){my($off,$size)=unpack('V2',substr($data,$at+8,8));die "Bad signature bounds\n"if$off<32+$szcmd||$off+$size>length$data;$sigoff=$off;substr($normalized,$at+8,8)="\0"x8;}
 if($cmd==0x19&&substr($data,$at+8,16)=~/^__LINKEDIT\0/){substr($normalized,$at+32,8)="\0"x8;substr($normalized,$at+48,8)="\0"x8;}
 if($cmd==0xc||$cmd==0x80000018||$cmd==0x8000001f||$cmd==0x20||$cmd==0x80000023||$cmd==0x8000001c){
  my$off=unpack('V',substr($data,$at+8,4));die "Bad load-command string\n"if$off>=$sz;
  my$name=substr($data,$at+$off,$sz-$off);$name=~s/\0.*\z//s;die "Unexpected control character\n"if$name=~/[\r\n]/;
  push@loads,sprintf("load_command_%08x=%s",$cmd,$name);
 }
 $at+=$sz;
}
die "Missing signature command\n"unless defined$sigoff;
print "normalized_content_sha256=",sha256_hex(substr($normalized,0,$sigoff)),"\n";
print "normalized_load_commands_sha256=",sha256_hex(substr($normalized,0,32+$szcmd)),"\n";
print join("\n",@loads),"\n";
