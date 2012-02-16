" $Id: .vimrc,v 1.2 2006/03/16 23:41:12 tak Exp $
" tak: Hacked up from yahoo!~crystal

" Because I like four-character tabs, but most people don't, expandtab
" replaces my tabs with spaces so it will look correct to everyone.
"
set expandtab
set ts=4
set shiftwidth=4
"set textwidth=66

filetype indent on


let g:ctags_statusline=1


" The default vim colors are good on a white background, but I use a dark
" background, so they're hard to see.  These colors are vivid and much
" prettier, and I recommend them if you use a dark background:
"
syntax on
highlight Boolean ctermfg=2 cterm=bold
highlight Character ctermfg=7 cterm=bold
highlight Comment ctermfg=6
highlight Conditional ctermfg=3 cterm=bold
highlight Constant ctermfg=5 cterm=bold
highlight Float ctermfg=6 cterm=bold
highlight Folded ctermfg=5 ctermbg=14 cterm=bold term=standout
highlight FoldColumn ctermfg=5 ctermbg=14 cterm=bold term=standout
highlight htmlTag ctermfg=2 cterm=bold
highlight htmlTagName ctermfg=3 cterm=bold
highlight htmlLink ctermfg=7 cterm=bold,underline
highlight htmlEndTag ctermfg=5 cterm=bold
highlight Identifier ctermfg=2 cterm=bold
highlight Include ctermfg=5 cterm=bold
highlight Label ctermfg=5 cterm=bold
highlight Macro ctermfg=5 cterm=bold
highlight Number ctermfg=6 cterm=bold
highlight Operator ctermfg=7 cterm=bold
highlight Special ctermfg=2 cterm=none
highlight SpecialChar ctermfg=7 cterm=bold
highlight Search term=reverse ctermbg=4 ctermfg=3
highlight Statement ctermfg=3 cterm=bold
highlight StorageClass ctermfg=3 cterm=bold
highlight String ctermfg=6 cterm=bold
highlight Title ctermfg=5 cterm=bold
highlight Type ctermfg=2 cterm=bold
highlight VimOption ctermfg=5 cterm=bold
highlight VimEnvVar ctermfg=5 cterm=bold
highlight VimHiAttrib ctermfg=5 cterm=bold
highlight PreProc ctermfg=5 cterm=bold


" This avoids the # flying to the left when using cindent :-)
set cinkeys=0{,0},0),:,!^F,o,O,e


" Incremental search (show matches while you're still typing the search term)
set incsearch


" These look like this, and position your cursor at the proper location to
" begin typing:
"
"    int main(void)
"    {
"        <cursor goes here>
"
"        return 0;
"    }
"
iab imz <esc>:set paste<cr>iint main()<cr>{<cr><esc>i<cr><esc>XXXXi}<cr><up><up><space><space><space><esc>:set nopaste<cr>i<right>
iab imc int main(int argc, char **argv<right><cr>{<cr><esc>XXXXi<space><space><space>
iab imt int main(int argc, char **argv<right> try<cr>{<cr><down><down><cr>catch (exception &e<right><cr>{<cr>cerr <lt><lt> "Caught fatal exception \"" <lt><lt> e.what(<right> <lt><lt> "\", quitting\n";<esc>^4ki
set dictionary+=/usr/share/dict/words

" go to marks more easily (type ma to set mark a, then za to go to mark a)
nmap z `

nnoremap e e
nnoremap E E
nnoremap w b
nnoremap W B

" Add shebang lines quickly
"
iab 3bs #!/bin/sh<cr><cr><up><up><right><right><right><right><right><right><right><right><right>
iab 3bas #!/usr/local/bin/bash<cr><cr><up><up><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right>
iab 3pl #!/usr/local/bin/perl -w<cr>use strict;

iab `` ############################################################################<cr>#<cr>#<cr>#<cr><up><up><right><space>



" comment out a block with #'s, or remove those leading #'s
" not implemented for C++-style; use #if blocks instead.
" the " one is for .vimrc
vmap # :s/^/# /<cr>
vmap <space> :s/^# //<cr>
vmap " :s/^/" /<cr>
vmap ' :s/^" //<cr>

" These let you indent a block without hitting shift, easier on the wrist :-)
vmap , <
vmap . >



" create neat little frames around your text, to aid in prettyprinting
" this is useful when youre making a quick and dirty script but still
" want it to look nice and readable, without putting much time in
" it looks like one of these two when you are done (QW for ##, AS for /*):
"
"   ########################   /**********************/
"   ##                    ##   /*                    */
"   ##  Here's some text  ##   /*  Here's some text  */
"   ##                    ##   /*                    */
"   ########################   /**********************/

map A :s/##  \(.*\)  ##/\1/<cr>kkd2djd2dk
map S :s/\(.*\)/##  \1  ##/<cr>yy4P:s/./#/g<cr>j:s/[^#]/ /g<cr>jj:s/[^#]/ /g<cr>j:s/./#/g<cr>2k4l



" Draw horizontal lines rapidly (I use these in my diary textfile to separate
" entries, but they could be useful jotting down notes in vim any time you
" want to separate ideas)
iab =-= ==================
iab -=- ----------------------------------------

" Use my custom rxvt title
"
set notitle

" Search upward from cwd to get tags file, not sure of a better way
" to do this but let me know if you know one
"
set tags=tags,../tags,../../tags,../../../tags,../../../../tags,../../../../../tags,../../../../../../tags

" Kill the numbers and auto-cindent at once, or turn them back on together.
" This is to make it easy for me to cut+paste from one window to another,
" by hitting ! first in both windows, then @ in both windows once I am done
" cutting+pasting.
map ! :set nonu<cr>:set paste<cr>
map @ :set nu<cr>:set nopaste<cr>


" Just so you can keep holding shift:
nmap :W :w
nmap :X :x
nmap :Q :q


" Remove trailing whitespace
nmap <F5> :%s/ \s*$//g<CR>


" Shortcut to type :perldo, to use perl RE engine instead of built-in
nmap <F7> :perldo


" Toggle search highlighting (off by default), annoying to leave this on
nmap <F8> :set hls!<CR>


" Misc things
set viminfo=%,'50,\"100,:100,n~/.viminfo
set shortmess+=I
set ruler
set ignorecase smartcase
set cpoptions=aABceFs

set confirm             " To get a dialog when a command fails
set history=100         " Number of history commands to remember
set showcmd             " Show (partial) command in status line

" set nofoldenable
set number

autocmd! BufReadPost
autocmd BufReadPost * '"



" This is a hack and I don't recommend you use it in your own .vimrc :-)
set term=screen


" We want .inc to go to .php--okay this is a hack but it fits in .vimrc
" without changing anything elsewhere, so I can take it from install to
" install without worries :-)  You may not need this, depending on your
" VIM version.
"
augroup filetypedetect
    au! BufRead,BufNewFile *.inc          setfiletype php
    au! BufRead,BufNewFile *crontab*      setfiletype crontab
augroup END


" spell checker--uses bin/spell wrapper to ispell
"
" map ,s :!spell <cword><return>

" remove msquotes?? v0.1
" map ,z :%s/กษ/"/g<return>:%s/กว/'/g<return>:%s/กศ/"/g<return>


" unfold folded text
"
" merging home and work .vimrc's, i find this:
"
"   home: map ,f zA
"   work: map ,f zfzaza
"
" which one should i use??

" map ,f zfzaza

map C :n<cr>
map B :prev<cr>



" Tab completion (or insert normal tab if not in the middle of a word)
"
function! InsertTabWrapper(direction)
    let col = col('.') - 1
    if !col || getline('.')[col - 1] !~ '\k'
        return "\<tab>"
    elseif "backward" == a:direction
        return "\<c-p>"
    else
        return "\<c-n>"
    endif
endfunction

function! InsertOpenCurlyBraceWrapper()
    let col = col('.') - 1
    if !col || getline('.')[col - 1] !~ '[\k$]'
        return "{\<cr>}\<up>"
    else
        return "{}\<left>"
    endif
endfunction


inoremap <tab> <c-r>=InsertTabWrapper ("forward")<cr>
inoremap <s-tab> <c-r>=InsertTabWrapper ("backward")<cr>

set dictionary=

set complete=.,w,b,u,t,k

:au FileType * let &dictionary = substitute("~/vimdict/FT.dict", "FT", &filetype, "")

" for build2
map M :w!<cr>:!(cd ~/p && gmake html)<cr><cr>
map L :w!<cr>:!(cd ~/p && gmake conf)<cr><cr>


:au Filetype make call RealTab()
:au Filetype TSV call RealTab()
:au Filetype crontab call RealTab()

function! RealTab()
    inoremap <tab> <tab>
    set noexpandtab
endfunction


" I use these special bindings for C and C++ to save myself a lot of
" repeated typing.  Note the distinction beween #i/#f and #I/#F.
:au Filetype c,cpp call SetCBindings()
function! SetCBindings()
    set noautoindent
    set cindent
    set textwidth=78
    inoremap #d #define<space>
    inoremap #i #include <lt>><left>
    inoremap #I #include ""<left>
    inoremap #F #ifdef<space>
    inoremap #z #if 0<cr>
    inoremap #f #if
    inoremap #<Char-48> #if 0<cr>
    inoremap #Z <esc>yyP:s/^/#ifndef <cr>j:s/^/#define <cr>
    inoremap #e #endif<cr>
    inoremap #n #ifndef<space>
    inoremap #u #undef<space>
    iab uns using namespace std;
    iab `` <esc>:set paste<cr>i<home>////////////////////////////////////////////////////////////////////////////<cr>//<cr>//<cr>//<cr><up><up><right><right><space><esc>:set nopaste<cr>i<space>i
    map A :s/\/\*  \(.*\)  \*\//\1/<cr>kkd2djd2dk
    map S :s/\(.*\)/\/*  \1  *\// <cr>yy4P:s/[^/]/*/g<cr>j:s/[^/]/ /g<cr>:s/^../\/*/g<cr>:s/..$/*\//g<cr>jj:s/[^/]/ /g<cr>:s/^../\/*/g<cr>:s/..$/*\//g<cr>j:s/[^/]/*/g<cr>2k4l

    " Here's an alternate version, with C-style comments.
    " I'm not sure which version I like better, but I'm going with the
    " C++-style comments for now, so I'm leaving this commented out.
    "
    "iab `` <esc>:set paste<cr>i<home>/**************************************************************************<cr> *<cr> *<cr> *<cr> */<cr><up><up><up><right><right><space><esc>:set nopaste<cr>i<space>

    " insert std:: quickly
    inoremap @@ std::

    inoremap `[ [
    inoremap `( (
    inoremap `{ {

    inoremap { <c-r>=InsertOpenCurlyBraceWrapper ()<cr>
    inoremap [ []<left>
    inoremap ( ()<left>

    " Add cvsid to the top of the file
    imap #c <esc>:1<cr>:set paste<cr>istatic const char __attribute__((unused))<cr>*cvsid = "$Id: .vimrc,v 1.2 2006/03/16 23:41:12 tak Exp $";<cr><cr><esc>:set nopaste<cr>

endfunction

:au Filetype perl call SetPerlBindings()
function! SetPerlBindings()
    set noautoindent
    set cindent
    set textwidth=78
    inoremap `[ [
    inoremap `( (
    inoremap `{ {

    inoremap { <c-r>=InsertOpenCurlyBraceWrapper ()<cr>
    inoremap [ []<left>
    inoremap ( ()<left>

endfunction

:au Filetype php call SetPhpBindings()
function! SetPhpBindings()
    set noautoindent
    set cindent
    set textwidth=78
    inoremap `[ [
    inoremap `( (
    inoremap `{ {

    inoremap { <c-r>=InsertOpenCurlyBraceWrapper ()<cr>
    inoremap [ []<left>
    inoremap ( ()<left>

endfunction

" Get rid of auto-indent behavior that moves # to first column,
" need to replace ^Cs with ^Os when I can type them.  ;p
":inoremap # a#hxA


" --------------------------------------------------------------------------
" Disabled things I'm leaving in here in case I want to know how to do them:
" --------------------------------------------------------------------------
"
" " Lets you see ^Ms when editing DOS files
"   set fileformats=unix
"
" " Useful for editing text files (I should figure out how to set this
" " automatically in the cases I want it on!)
"   set textwidth=76
"
" " todo: make this context-sensitive and reenable:
" "      Close parens, quotes, etc
"   :inoremap ( ()<Left>
"   :inoremap [ []<Left>
"   :inoremap " <C-V>"<C-V>"<left>
"   :inoremap < <lt>><Left>
" --------------------------------------------------------------------------


" Load skeletons
"
autocmd BufNewFile *.h call NewHFile()
fun NewHFile()
    0r ~/vimskel/skel.h
endfun
autocmd BufNewFile *.php call NewPhpFile()
fun NewPhpFile()
    0r ~/vimskel/skel.php
endfun
autocmd BufNewFile *.html call NewHtmlFile()
fun NewHtmlFile()
    0r ~/vimskel/skel.html
endfun
autocmd BufNewFile *.pm call NewPMFile()
fun NewPMFile()
    0r ~/vimskel/skel.pm
endfun



" " TODO: make the following work!  I don't want to do one hack per FT
" "
"
" :au FileType * let b:skelfile = substitute("~/vimskel/skel.FT", "FT", &filetype, "")
" :au BufNewFile execute "0r " . b:skelfile
" if exists(b:skelfile)



map _F ma[[k"xyy`a:echo @x<CR>

