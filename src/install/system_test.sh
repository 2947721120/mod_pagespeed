#!/bin/bash
# Copyright 2010 Google Inc. All Rights Reserved.
# Author: abliss@google.com (Adam Bliss)
#
# Generic system test, which should work on any implementation of
# Page Speed Automatic (not just the Apache module).
# Exits with status 0 if all tests pass.  Exits 1 immediately if any test fails.

if [ $# -lt 1 -o $# -gt 2 ]; then
  # Note: HOSTNAME should generally be localhost:PORT. Specifically, by default
  # /mod_pagespeed_statistics is only accessible when accessed as localhost.
  echo Usage: ./system_test.sh HOSTNAME [PROXY_HOST]
  exit 2
fi;

TEMPDIR=${TEMPDIR-/tmp/mod_pagespeed_test.$USER}

# If the user has specified an alternate WGET as an environment variable, then
# use that, otherwise use the one in the path.
if [ "$WGET" == "" ]; then
  WGET=wget
else
  echo WGET = $WGET
fi

$WGET --version | head -1 | grep 1.12 >/dev/null
if [ $? != 0 ]; then
  echo You have the wrong version of wget.  1.12 is required.
  exit 1
fi

# We need to set a wgetrc file because of the stupid way that the bash deals
# with strings and variable expansion.
mkdir -p $TEMPDIR || exit 1
export WGETRC=$TEMPDIR/wgetrc
# Use a Chrome User-Agent, so that we get real responses (including compression)
cat > $WGETRC <<EOF
user_agent = "Mozilla/5.0 (X11; U; Linux x86_64; en-US) AppleWebKit/534.0 (KHTML, like Gecko) Chrome/6.0.408.1 Safari/534.0"
EOF

HOSTNAME=$1
EXAMPLE_ROOT=http://$HOSTNAME/mod_pagespeed_example
TEST_ROOT=http://$HOSTNAME/mod_pagespeed_test
STATISTICS_URL=http://$HOSTNAME/mod_pagespeed_statistics
BAD_RESOURCE_URL=http://$HOSTNAME/mod_pagespeed/bad.pagespeed.cf.hash.css
MESSAGE_URL=http://$HOSTNAME/mod_pagespeed_message

# Setup wget proxy information
export http_proxy=$2
export https_proxy=$2
export ftp_proxy=$2
export no_proxy=""

# Version timestamped with nanoseconds, making it extremely unlikely to hit.
BAD_RND_RESOURCE_URL="http://$HOSTNAME/mod_pagespeed/bad`date +%N`.\
pagespeed.cf.hash.css"

combine_css_filename=\
styles/yellow.css+blue.css+big.css+bold.css.pagespeed.cc.xo4He3_gYf.css

OUTDIR=$TEMPDIR/fetched_directory
rm -rf $OUTDIR

# Wget is used three different ways.  The first way is nonrecursive and dumps a
# single page (with headers) to standard out.  This is useful for grepping for a
# single expected string that's the result of a first-pass rewrite:
#   wget -q -O --save-headers - $URL | grep -q foo
# "-q" quells wget's noisy output; "-O -" dumps to stdout; grep's -q quells
# its output and uses the return value to indicate whether the string was
# found.  Note that exiting with a nonzero value will immediately kill
# the make run.
#
# Sometimes we want to check for a condition that's not true on the first dump
# of a page, but becomes true after a few seconds as the server's asynchronous
# fetches complete.  For this we use the the fetch_until() function:
#   fetch_until $URL 'grep -c delayed_foo' 1
# In this case we will continuously fetch $URL and pipe the output to
# grep -c (which prints the count of matches); we repeat until the number is 1.
#
# The final way we use wget is in a recursive mode to download all prerequisites
# of a page.  This fetches all resources associated with the page, and thereby
# validates the resources generated by mod_pagespeed:
#   wget -H -p -S -o $WGET_OUTPUT -nd -P $OUTDIR $EXAMPLE_ROOT/$FILE
# Here -H allows wget to cross hosts (e.g. in the case of a sharded domain); -p
# means to fetch all prerequisites; "-S -o $WGET_OUTPUT" saves wget output
# (including server headers) for later analysis; -nd puts all results in one
# directory; -P specifies that directory.  We can then run commands on
# $OUTDIR/$FILE and nuke $OUTDIR when we're done.
# TODO(abliss): some of these will fail on windows where wget escapes saved
# filenames differently.
# TODO(morlovich): This isn't actually true, since we never pass in -r,
#                  so this fetch isn't recursive. Clean this up.


WGET_OUTPUT=$OUTDIR/wget_output.txt
WGET_DUMP="$WGET -q -O - --save-headers"
WGET_PREREQ="$WGET -H -p -S -o $WGET_OUTPUT -nd -P $OUTDIR -e robots=off"

# Call with a command and its args.  Echos the command, then tries to eval it.
# If it returns false, fail the tests.
function check() {
  echo "     " $@
  if eval "$@"; then
    return;
  else
    echo FAIL.
    exit 1;
  fi;
}

# Continuously fetches URL and pipes the output to COMMAND.  Loops until
# COMMAND outputs RESULT, in which case we return 0, or until 10 seconds have
# passed, in which case we return 1.
function fetch_until() {
  # Should not user URL as PARAM here, it rewrites value of URL for
  # the rest tests.
  REQUESTURL=$1
  COMMAND=$2
  RESULT=$3
  USERAGENT=$4

  TIMEOUT=10
  START=`date +%s`
  STOP=$((START+$TIMEOUT))
  WGET_HERE="$WGET -q"
  if [[ -n "$USERAGENT" ]]; then
    WGET_HERE="$WGET -q -U $USERAGENT"
  fi
  echo "     " Fetching $REQUESTURL until '`'$COMMAND'`' = $RESULT
  while test -t; do
    if [ "$($WGET_HERE -O - $REQUESTURL 2>&1 | $COMMAND)" = "$RESULT" ]; then
      /bin/echo ".";
      return;
    fi;
    if [ `date +%s` -gt $STOP ]; then
      /bin/echo "FAIL."
      exit 1;
    fi;
    /bin/echo -n "."
    sleep 0.1
  done;
}

# Helper to set up most filter tests
function test_filter() {
  rm -rf $OUTDIR
  mkdir -p $OUTDIR
  FILTER_NAME=$1;
  shift;
  FILTER_DESCRIPTION=$@
  echo TEST: $FILTER_NAME $FILTER_DESCRIPTION
  FILE=$FILTER_NAME.html?ModPagespeedFilters=$FILTER_NAME
  URL=$EXAMPLE_ROOT/$FILE
  FETCHED=$OUTDIR/$FILE
}

# Helper to test if we mess up extensions on requests to broken url
function test_resource_ext_corruption() {
  URL=$1
  RESOURCE=$EXAMPLE_ROOT/$2

  # Make sure the resource is actually there, that the test isn't broken
  echo checking that wgetting $URL finds $RESOURCE ...
  $WGET_DUMP $URL | grep -qi $RESOURCE
  check [ $? = 0 ]

  # Now fetch the broken version
  BROKEN="$RESOURCE"broken
  $WGET_PREREQ $BROKEN
  check [ $? != 0 ]

  # Fetch normal again; ensure rewritten url for RESOURCE doesn't contain broken
  $WGET_DUMP $URL | grep broken
  check [ $? != 0 ]
}

# General system tests

echo TEST: Page Speed Automatic is running and writes the expected header.
echo $WGET_DUMP $EXAMPLE_ROOT/combine_css.html
HTML_HEADERS=$($WGET_DUMP $EXAMPLE_ROOT/combine_css.html)

echo Checking for X-Mod-Pagespeed header
echo $HTML_HEADERS | grep -qi X-Mod-Pagespeed
check [ $? = 0 ]

echo Checking for lack of E-tag
echo $HTML_HEADERS | grep -qi Etag
check [ $? != 0 ]

echo Checking for presence of Vary.
echo $HTML_HEADERS | grep -qi 'Vary: Accept-Encoding'
check [ $? = 0 ]

echo Checking for absence of Last-Modified
echo $HTML_HEADERS | grep -qi 'Last-Modified'
check [ $? != 0 ]

echo Checking for presence of Cache-Control: max-age=0, no-cache, no-store
echo $HTML_HEADERS | grep -qi 'Cache-Control: max-age=0, no-cache, no-store'
check [ $? = 0 ]

echo Checking for absense of Expires
echo $HTML_HEADERS | grep -qi 'Expires'
check [ $? != 0 ]

# This tests whether fetching "/" gets you "/index.html".  With async
# rewriting, it is not deterministic whether inline css gets
# rewritten.  That's not what this is trying to test, so we use
# ?ModPagespeed=off.
echo TEST: directory is mapped to index.html.
rm -rf $OUTDIR
mkdir -p $OUTDIR
check "$WGET -q $EXAMPLE_ROOT/?ModPagespeed=off" \
    -O $OUTDIR/mod_pagespeed_example
check "$WGET -q $EXAMPLE_ROOT/index.html?ModPagespeed=off" -O $OUTDIR/index.html
check diff $OUTDIR/index.html $OUTDIR/mod_pagespeed_example

echo TEST: compression is enabled for HTML.
check "$WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $EXAMPLE_ROOT/ 2>&1 | grep -qi 'Content-Encoding: gzip'"

echo TEST: X-Mod-Pagespeed header added when ModPagespeed=on
$WGET_DUMP $EXAMPLE_ROOT/combine_css.html?ModPagespeed=on \
  | grep -i X-Mod-Pagespeed
check [ $? = 0 ]

#echo TEST: X-Mod-Pagespeed header not added when ModPagespeed=off
#$WGET_DUMP $EXAMPLE_ROOT/combine_css.html?ModPagespeed=off \
#  | grep -i X-Mod-Pagespeed
#check [ $? != 0 ]


# Individual filter tests, in alphabetical order

test_filter add_instrumentation adds 2 script tags
check $WGET_PREREQ $URL
check [ `cat $FETCHED | sed 's/>/>\n/g' | grep -c '<script'` = 2 ]

echo "TEST: We don't add_instrumentation if URL params tell us not to"
FILE=add_instrumentation.html?ModPagespeedFilters=
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
check $WGET_PREREQ $URL
check [ `cat $FETCHED | sed 's/>/>\n/g' | grep -c '<script'` = 0 ]

# http://code.google.com/p/modpagespeed/issues/detail?id=170
echo "TEST: Make sure 404s aren't rewritten"
# Note: We run this in the add_instrumentation section because that is the
# easiest to detect which changes every page
THIS_BAD_URL=$BAD_RESOURCE_URL?ModPagespeedFilters=add_instrumentation
# We use curl, because wget does not save 404 contents
curl --silent $THIS_BAD_URL | grep /mod_pagespeed_beacon
check [ $? != 0 ]

test_filter collapse_whitespace removes whitespace, but not from pre tags.
check $WGET_PREREQ $URL
check [ `egrep -c '^ +<' $FETCHED` = 1 ]

test_filter combine_css combines 4 CSS files into 1.
fetch_until $URL 'grep -c text/css' 1
check $WGET_PREREQ $URL
# TODO(sligocki): This does not work in rewrite_proxy_server
# because of hash mismatch. Do we want to enforce hash consistency between
# rewrite_proxy_server and mod_pagespeed?
#test_resource_ext_corruption $URL $combine_css_filename

echo TEST: combine_css without hash field should 404
echo $WGET_PREREQ $EXAMPLE_ROOT/styles/yellow.css+blue.css.pagespeed.cc..css
$WGET_PREREQ $EXAMPLE_ROOT/styles/yellow.css+blue.css.pagespeed.cc..css
check grep '"404 Not Found"' $WGET_OUTPUT

# Note: this large URL can only be processed by Apache if
# ap_hook_map_to_storage is called to bypass the default
# handler that maps URLs to filenames.
echo TEST: Fetch large css_combine URL
LARGE_URL="$EXAMPLE_ROOT/styles/yellow.css+blue.css+big.css+\
bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+\
bold.css.pagespeed.cc.46IlzLf_NK.css"
echo "$WGET --save-headers -q -O - $LARGE_URL | head -1 | grep \"HTTP/1.1 200 OK\""
$WGET --save-headers -q -O - $LARGE_URL | head -1 | grep -e "HTTP/1\.. 200 OK"
check [ $? = 0 ];
LARGE_URL_LINE_COUNT=$($WGET -q -O - $LARGE_URL | wc -l)
check [ $? = 0 ]
echo Checking that response body is at least 900 lines -- it should be 954
check [ $LARGE_URL_LINE_COUNT -gt 900 ]

test_filter combine_javascript combines 2 JS files into 1.
fetch_until $URL 'grep -c src=' 1
check $WGET_PREREQ $URL

test_filter combine_heads combines 2 heads into 1
check $WGET_PREREQ $URL
check [ `grep -ce '<head>' $FETCHED` = 1 ]

test_filter elide_attributes removes boolean and default attributes.
check $WGET_PREREQ $URL
grep "disabled=" $FETCHED   # boolean, should not find
check [ $? != 0 ]
grep "type=" $FETCHED       # default, should not find
check [ $? != 0 ]

test_filter extend_cache rewrites an image tag.
fetch_until $URL 'grep -c src.*/Puzzle.jpg.pagespeed.ce.*.jpg' 1
check $WGET_PREREQ $URL
echo about to test resource ext corruption...
# TODO(sligocki): This does not work in rewrite_proxy_server
# because of hash mismatch. Do we want to enforce hash consistency between
# rewrite_proxy_server and mod_pagespeed?
#test_resource_ext_corruption $URL images/Puzzle.jpg.pagespeed.ce.91_WewrLtP.jpg

echo TEST: Attempt to fetch cache-extended image without hash should 404
$WGET_PREREQ $EXAMPLE_ROOT/images/Puzzle.jpg.pagespeed.ce..jpg
check grep '"404 Not Found"' $WGET_OUTPUT

echo TEST: Cache-extended image should respond 304 to an If-Modified-Since.
URL=$EXAMPLE_ROOT/images/Puzzle.jpg.pagespeed.ce.91_WewrLtP.jpg
DATE=`date -R`
$WGET_PREREQ --header "If-Modified-Since: $DATE" $URL
check grep '"304 Not Modified"' $WGET_OUTPUT

echo TEST: Legacy format URLs should still work.
URL=$EXAMPLE_ROOT/images/ce.0123456789abcdef0123456789abcdef.Puzzle,j.jpg
# Note: Wget request is HTTP/1.0, so some servers respond back with
# HTTP/1.0 and some respond back 1.1.
check "$WGET_DUMP $URL | grep -qe 'HTTP/1\.. 200 OK'"

test_filter move_css_to_head does what it says on the tin.
check $WGET_PREREQ $URL
check grep -q "'styles/all_styles.css\"></head>'" $FETCHED  # link moved to head

test_filter inline_css converts a link tag to a style tag
fetch_until $URL 'grep -c style' 2

test_filter inline_javascript inlines a small JS file
fetch_until $URL 'grep -c document.write' 1

test_filter outline_css outlines large styles, but not small ones.
check $WGET_PREREQ $URL
check egrep -q "'<link.*text/css.*large'" $FETCHED  # outlined
check egrep -q "'<style.*small'" $FETCHED           # not outlined

test_filter outline_javascript outlines large scripts, but not small ones.
check $WGET_PREREQ $URL
check egrep -q "'<script.*large.*src='" $FETCHED       # outlined
check egrep -q "'<script.*small.*var hello'" $FETCHED  # not outlined
echo TEST: compression is enabled for rewritten JS.
JS_URL=$(egrep -o http://.*.pagespeed.*.js $FETCHED)
echo JS_URL=\$\(egrep -o http://.*.pagespeed.*.js $FETCHED\)=\"$JS_URL\"
JS_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $JS_URL 2>&1)
echo JS_HEADERS=$JS_HEADERS
echo $JS_HEADERS | grep -qie 'HTTP/1\.. 200 OK'
check [ $? = 0 ]
echo $JS_HEADERS | grep -qi 'Content-Encoding: gzip'
check [ $? = 0 ]
#echo $JS_HEADERS | grep -qi 'Vary: Accept-Encoding'
#check [ $? = 0 ]
echo $JS_HEADERS | grep -qi 'Etag: W/0'
check [ $? = 0 ]
echo $JS_HEADERS | grep -qi 'Last-Modified:'
check [ $? = 0 ]

test_filter remove_comments removes comments but not IE directives.
check $WGET_PREREQ $URL
grep "removed" $FETCHED                # comment, should not find
check [ $? != 0 ]
check grep -q preserved $FETCHED       # preserves IE directives

test_filter remove_quotes does what it says on the tin.
check $WGET_PREREQ $URL
check [ `sed 's/ /\n/g' $FETCHED | grep -c '"' ` = 2 ]  # 2 quoted attrs
check [ `grep -c "'" $FETCHED` = 0 ]                    # no apostrophes

test_filter trim_urls makes urls relative
check $WGET_PREREQ $URL
grep "mod_pagespeed_example" $FETCHED     # base dir, shouldn't find
check [ $? != 0 ]
check [ `stat -c %s $FETCHED` -lt 153 ]   # down from 157

test_filter rewrite_css removes comments and saves a bunch of bytes.
check $WGET_PREREQ $URL
grep "comment" $FETCHED                   # comment, should not find
check [ $? != 0 ]
check [ `stat -c %s $FETCHED` -lt 680 ]   # down from 689

test_filter rewrite_images inlines, compresses, and resizes.
fetch_until $URL 'grep -c data:image/png' 1  # inlined
fetch_until $URL 'grep -c .pagespeed.ic' 2   # other 2 images optimized
check $WGET_PREREQ $URL
ls -l $OUTDIR
check [ "$(stat -c %s $OUTDIR/xBikeCrashIcn*)" -lt 25000 ]      # re-encoded
check [ "$(stat -c %s $OUTDIR/*256x192*Puzzle*)"  -lt 24126  ]  # resized
URL=$EXAMPLE_ROOT"/rewrite_images.html?ModPagespeedFilters=rewrite_images"
IMG_URL=$(egrep -o http://.*.pagespeed.*.jpg $FETCHED | head -n1)
echo TEST: headers for rewritten image "$IMG_URL"
IMG_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $IMG_URL 2>&1)
echo IMG_HEADERS=\"$IMG_HEADERS\"
echo $IMG_HEADERS | grep -qie 'HTTP/1\.. 200 OK'
check [ $? = 0 ]
# Make sure we have some valid headers.
echo "$IMG_HEADERS" | grep -qi 'Content-Type: image/jpeg'
check [ $? = 0 ]
# Make sure the response was not gzipped.
echo TEST: Images are not gzipped
echo "$IMG_HEADERS" | grep -qi 'Content-Encoding: gzip'
check [ $? != 0 ]
# Make sure there is no vary-encoding
echo TEST: Vary is not set for images
echo "$IMG_HEADERS" | grep -qi 'Vary: Accept-Encoding'
check [ $? != 0 ]
# Make sure there is an etag
echo TEST: Etags is present
echo "$IMG_HEADERS" | grep -qi 'Etag: W/0'
check [ $? = 0 ]
# TODO(sligocki): Allow setting arbitrary headers in static_server.
# Make sure an extra header is propagated from input resource to output
# resource.  X-Extra-Header is added in debug.conf.template.
#echo TEST: Extra header is present
#echo "$IMG_HEADERS" | grep -qi 'X-Extra-Header'
#check [ $? = 0 ]
# Make sure there is a last-modified tag
echo TEST: Last-modified is present
echo "$IMG_HEADERS" | grep -qi 'Last-Modified'
check [ $? = 0 ]

BAD_IMG_URL=$EXAMPLE_ROOT/images/xBadName.jpg.pagespeed.ic.Zi7KMNYwzD.jpg
echo TEST: rewrite_images fails broken image \"$BAD_IMG_URL\"
echo $WGET_PREREQ $BAD_IMG_URL
$WGET_PREREQ $BAD_IMG_URL  # fails
check grep '"404 Not Found"' $WGET_OUTPUT

# [google] b/3328110
echo "TEST: rewrite_images doesn't 500 on unoptomizable image"
IMG_URL=$EXAMPLE_ROOT/images/xOptPuzzle.jpg.pagespeed.ic.Zi7KMNYwzD.jpg
$WGET_PREREQ $IMG_URL
check grep -e '"HTTP/1\.. 200 OK"' $WGET_OUTPUT

# These have to run after image_rewrite tests. Otherwise it causes some images
# to be loaded into memory before they should be.
test_filter rewrite_css,extend_cache extends cache of images in CSS
FILE=rewrite_css_images.html?ModPagespeedFilters=$FILTER_NAME
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
fetch_until $URL 'grep -c .pagespeed.ce.' 1  # image cache extended
check $WGET_PREREQ $URL

test_filter rewrite_css,rewrite_images rewrites images in CSS
FILE=rewrite_css_images.html?ModPagespeedFilters=$FILTER_NAME
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
fetch_until $URL 'grep -c .pagespeed.ic.' 1  # image rewritten
check $WGET_PREREQ $URL

# This test is only valid for async.
test_filter inline_css,rewrite_css,sprite_images sprites images in CSS
FILE=sprite_images.html?ModPagespeedFilters=$FILTER_NAME
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
echo $WGET_DUMP $URL
fetch_until $URL 'grep -c ic.pagespeed.is' 1

# This test is only valid for async.
test_filter rewrite_css,sprite_images sprites images in CSS
FILE=sprite_images.html?ModPagespeedFilters=$FILTER_NAME
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
echo $WGET_DUMP $URL
fetch_until $URL 'grep -c css.pagespeed.cf' 1
echo $WGET_DUMP $URL
$WGET_DUMP $URL > $OUTDIR/sprite_output
CSS=`grep stylesheet $OUTDIR/sprite_output | cut -d\" -f 6`
echo css is $CSS
$WGET_DUMP $CSS > $OUTDIR/sprite_css_output
cat $OUTDIR/sprite_css_output
echo ""
check [ `grep -c "ic.pagespeed.is" $OUTDIR/sprite_css_output` -gt 0 ]

test_filter rewrite_javascript removes comments and saves a bunch of bytes.
# External scripts rewritten.
fetch_until $URL 'grep -c src.*/rewrite_javascript\.js\.pagespeed\.jm\.' 2
check $WGET_PREREQ $URL
grep -R "removed" $OUTDIR                 # Comments, should not find any.
check [ $? != 0 ]
check [ "$(stat -c %s $FETCHED)" -lt 1560 ]  # Net savings
check grep -q preserved $FETCHED             # Preserves certain comments.
# Rewritten JS is cache-extended.
check grep -qi "'Cache-control: max-age=31536000'" $WGET_OUTPUT
check grep -qi "'Expires:'" $WGET_OUTPUT

# Error path for fetch of outlined resources that are not in cache leaked
# at one point of development.
echo TEST: regression test for RewriteDriver leak
$WGET -O /dev/null -o /dev/null $TEST_ROOT/_.pagespeed.jo.3tPymVdi9b.js

# Helper to test directive ModPagespeedForBots
# By default directive ModPagespeedForBots is off; otherwise image rewriting is
# disabled for bots while other filters such as inline_css still work.
function CheckBots() {
  ON=$1
  COMPARE=$2
  BOT=$3
  FILTER="?ModPagespeedFilters=inline_css,rewrite_images"
  PARAM="&ModPagespeedDisableForBots=$ON";
  FILE="bot_test.html"$FILTER
  # By default ModPagespeedDisableForBots is false, no need to set it in url.
  # If the test wants to set it explicitly, set it in url.
  if [[ $ON != "default" ]]; then
    FILE=$FILE$PARAM
  fi
  FETCHED=$OURDIR/$FILE
  URL=$TEST_ROOT/$FILE
  # Filters such as inline_css work no matter if ModPagespeedDisable is on
  # Fetch until CSS is inlined, so that we know rewriting succeeded.
  if [[ -n $BOT ]]; then
    fetch_until $URL 'grep -c style' 2 $BOT;
  else
    fetch_until $URL 'grep -c style' 2;
  fi
  # Check if the images are rewritten
  rm -f $OUTDIR/*png*
  rm -f $OUTDIR/*jpg*
  if [[ -n $BOT ]]; then
    check `$WGET_PREREQ -U $BOT $URL`;
  else
    check `$WGET_PREREQ $URL`;
  fi
  check [ `stat -c %s $OUTDIR/*BikeCrashIcn*` $COMPARE 25000 ] # recoded or not
  check [ `stat -c %s $OUTDIR/*Puzzle*`  $COMPARE 24126  ] # resized or not
}

echo "Test: UserAgent is a bot; ModPagespeedDisableForBots=off"
CheckBots 'off' '-lt' 'Googlebot/2.1'
echo "Test: UserAgent is a bot; ModPagespeedDisableForBots=on"
CheckBots 'on' '-gt' 'Googlebot/2.1'
echo "Test: UserAgent is a bot; ModPagespeedDisableForBots is default"
CheckBots 'default' '-lt' 'Googlebot/2.1'
echo "Test: UserAgent is not a bot, ModPagespeedDisableForBots=off"
CheckBots 'off' '-lt'
echo "Test: UserAgent is not a bot, ModPagespeedDisableForBots=on"
CheckBots 'on' '-lt'
echo "Test: UserAgent is not a bot, ModPagespeedDisableForBots is default"
CheckBots 'default' '-lt'

# Cleanup
rm -rf $OUTDIR
echo "PASS."
