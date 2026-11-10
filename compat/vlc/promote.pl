#!/usr/bin/perl
# Sonoma stock Perl + standard macOS tools. No Python/CLT/runtime install needed.
use strict;use warnings;use JSON::PP;use Digest::SHA qw(sha256_hex);use Getopt::Long qw(GetOptions);use File::Find;use File::Path qw(make_path);use File::Copy qw(copy);use File::Basename qw(dirname);use Cwd qw(abs_path);use FindBin;
my$action=shift//'';my%o;GetOptions(\%o,'candidate=s','app=s','config=s','backup=s','validated-gui-receipt=s','retain-current=s')or die"Bad options\n";
my$json=JSON::PP->new->canonical->pretty;sub bytes{open my$f,'<:raw',$_[0]or die$!;local$/;return scalar<$f>;}sub sha{return sha256_hex(bytes($_[0]));}sub readj{return decode_json(bytes($_[0]));}sub save{my($p,$v)=@_;open my$f,'>:raw',$p or die$!;print$f $json->encode($v);close$f or die$!;}
sub tree{my($root)=@_;my%files;find({no_chdir=>1,wanted=>sub{my$p=$File::Find::name;my$n=substr($p,length($root)+1);if(-l$p){$files{$n}='symlink:'.readlink$p;}elsif(-f$p){$files{$n}=sha($p);}}},$root);return\%files;}
sub same{return$json->encode($_[0])eq$json->encode($_[1]);}sub run{system(@_)==0 or die"Command failed: $_[0]\n";}
sub inactive{my($app)=@_;open my$p,'-|','/bin/ps','-axo','command='or die$!;while(<$p>){s/^\s+//;die"Close target VLC before changing it\n"if/^\Q$app\/Contents\/MacOS\/VLC\E(?:\s|$)/;}close$p;}
sub normalized{my($path)=@_;open my$p,'-|',$^X,"$FindBin::Bin/macho-content.pl",$path or die$!;local$/;my$text=<$p>;close$p or die"Mach-O identity failed\n";my($sha)=$text=~/^normalized_content_sha256=([a-f0-9]{64})$/m;die"Missing identity\n"unless$sha;return$sha;}
sub merge{my($text)=@_;my%values=('codec'=>'avcodec','avcodec-hurry-up'=>'0');my%seen;my@lines;for my$line(split/(?<=\n)/,$text){if($line=~/^\s*(codec|avcodec-hurry-up)\s*=/){my$k=$1;push@lines,"$k=$values{$k}\n"unless$seen{$k}++;}else{push@lines,$line;}}$lines[-1].="\n"if@lines&&$lines[-1]!~/\n\z/;for my$k('codec','avcodec-hurry-up'){push@lines,"$k=$values{$k}\n"unless$seen{$k};}return join'',@lines;}
sub absolute{my($p)=@_;die"All paths must be absolute\n"unless defined$p&&$p=~m{^/};return$p;}
my$backup=absolute($o{backup});
if($action eq'install'){
 my$app=absolute($o{app});my$config=absolute($o{config});my$candidate=absolute($o{candidate});my$gui=absolute($o{'validated-gui-receipt'});inactive($app);die"Expected existing nonsymlink .app and new backup\n"unless-d$app&&!-l$app&&$app=~/\.app\z/&&!-e$backup;
 my$m=readj("$candidate/manifest.json");my$source="$candidate/VLC Export Test.app";die"Source tree changed\n"unless same(tree($app),$m->{source_tree});
 die"Candidate Info/main content changed\n"unless sha("$source/Contents/Info.plist")eq$m->{source_Info_sha256}&&normalized("$source/Contents/MacOS/VLC")eq$m->{source_main_normalized};
 for my$n(keys%{$m->{signed_plugins}}){die"Candidate plugin changed\n"unless sha("$source/Contents/MacOS/plugins/$n")eq$m->{signed_plugins}{$n};}
 run('/usr/bin/codesign','--verify','--deep','--strict',$source);die"Separate operator-validated GUI receipt required\n"unless-f$gui;
 make_path(dirname($backup));die"Backup filesystem differs\n"unless(stat(dirname($backup)))[0]==(stat(dirname($app)))[0];mkdir$backup,0700 or die$!;
 my$stage="$app.henge-staged";die"Staging path exists\n"if-e$stage;my$before=-f$config?bytes($config):undef;my$after=merge($before//'');
 if(defined$before){copy($config,"$backup/vlcrc.before")or die$!;chmod 0600,"$backup/vlcrc.before";}
 run('/usr/bin/ditto',$source,$stage);my$candidate_tree=tree($stage);die"Copy mismatch\n"unless same($candidate_tree,tree($source));run('/usr/bin/codesign','--verify','--deep','--strict',$stage);
 my$r={schema=>1,app=>$app,config=>$config,original_tree=>$m->{source_tree},candidate_tree=>$candidate_tree,config_existed=>defined($before)?JSON::PP::true:JSON::PP::false,config_before_sha256=>defined($before)?sha256_hex($before):undef,config_after_sha256=>sha256_hex($after),candidate_manifest_sha256=>sha("$candidate/manifest.json"),gui_validation_receipt_sha256=>sha($gui),state=>'prepared',runtime=>'stock macOS Perl'};save("$backup/receipt.json",$r);inactive($app);
 die"App changed during preparation\n"unless same(tree($app),$r->{original_tree});die"Config changed during preparation\n"unless(defined$before?-f$config&&bytes($config)eq$before:!-e$config);
 rename$app,"$backup/VLC.app"or die$!;
 eval{rename$stage,$app or die$!;make_path(dirname($config));my$temp="$config.henge-new";die"Config staging exists\n"if-e$temp;open my$f,'>:raw',$temp or die$!;print$f $after;close$f or die$!;chmod(-e$config?(stat$config)[2]&0777:0600,$temp);rename$temp,$config or die$!;};
 if($@){my$error=$@;rename$app,"$backup/failed-candidate.app"if-e$app;rename"$backup/VLC.app",$app or die"Restore failed: $!\n";die$error;}
 $r->{state}='installed';save("$backup/receipt.json",$r);print"Installed normal VLC.app; perform normal-entry validation. Backup: $backup\n";
}elsif($action eq'restore'){
 my$r=readj("$backup/receipt.json");my$app=$r->{app};my$config=$r->{config};my$retain=absolute($o{'retain-current'});inactive($app);die"Expected installed receipt and new retention path\n"unless$r->{state}eq'installed'&&!-e$retain;
 die"App content changed; review before restore\n"unless same(tree($app),$r->{candidate_tree})&&same(tree("$backup/VLC.app"),$r->{original_tree});die"Preferences changed; merge manually before restore\n"unless-f$config&&sha($config)eq$r->{config_after_sha256};make_path(dirname($retain));die"Retention filesystem differs\n"unless(stat(dirname($retain)))[0]==(stat(dirname($app)))[0];rename$app,$retain or die$!;
 unless(rename"$backup/VLC.app",$app){rename$retain,$app;die"Original app restore failed\n";}
 if($r->{config_existed}){copy("$backup/vlcrc.before",$config)or die$!;}else{unlink$config or die$!;}$r->{state}='restored';$r->{retained_candidate}=$retain;save("$backup/receipt.json",$r);print"Original app/preferences restored; candidate retained\n";
}else{die"Usage: perl promote.pl install|restore --backup ABSOLUTE_PATH ...\n";}
