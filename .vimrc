call plug#begin("~/.vim/plugged")
" EASE OF USE
Plug 'mg979/vim-visual-multi', {'branch': 'test'}
Plug 'mbbill/undotree'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-dispatch'
Plug 'SirVer/ultisnips'
Plug 'honza/vim-snippets'
Plug 'github/copilot.vim'
Plug 'mcchrish/nnn.vim'
" FORMATING
Plug 'godlygeek/tabular'
Plug 'vim-syntastic/syntastic'
Plug 'Raimondi/delimitMate'
Plug 'psf/black'
Plug 'dense-analysis/ale'
" COSMATICS
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'ryanoasis/vim-devicons'
Plug 'frazrepo/vim-rainbow'
Plug 'Yggdroot/indentLine'
Plug 'morhetz/gruvbox'
Plug 'junegunn/goyo.vim'
" Plug 'glacambre/firenvim', { 'do': { _ -> firenvim#install(0) } }
call plug#end()

let g:airline_theme='base16_gruvbox_dark_hard'
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#left_sep = ' '
let g:airline#extensions#tabline#left_alt_sep = '|'

let g:rainbow_active = 1
set conceallevel=1
set list lcs=tab:\┊\ 
let g:indentLine_enabled = 1
let g:indentLine_char = '┊'
let g:indentLine_setConceal = 0

" SYNTASTIC
set statusline+=%#warningmsg#
set statusline+=%{SyntasticStatuslineFlag()}
set statusline+=%*

let g:syntastic_python_checkers = ['flake8']
let g:syntastic_python_flake8_args = '--ignore=E501,W503,W504'
let g:syntastic_always_populate_loc_list = 1
let g:syntastic_auto_loc_list = 1
let g:syntastic_check_on_open = 1
let g:syntastic_check_on_wq = 0

" ULTISNIP
let g:UltiSnipsExpandTrigger="<tab>"
let g:UltiSnipsJumpForwardTrigger="<tab>"
let g:UltiSnipsJumpBackwardTrigger="<s-tab>"


let mapleader = ","
filetype plugin indent on
syntax on
colorscheme gruvbox
hi Normal ctermbg=None

" SETTINGS
set hidden
set t_Co=256
set bg=dark
set go=a
" set mouse=a
set encoding=utf8
set pastetoggle=<F2>
set clipboard=unnamedplus
set wildmode=longest,list,full
set showmatch
set history=700
set undolevels=700
set hlsearch
set ignorecase
set smartcase
set lazyredraw
set ttyfast

autocmd! BufWritePost *.ms :!groff -ms % -Tps -dpaper=a4 -R -e -k -p -t | ps2pdf - > <afile>.pdf
autocmd! BufWritePost vimrc source %
" autocmd BufWritePre *.py execute ':Black'
autocmd TextYankPost * call system('echo '.shellescape(join(v:event.regcontents, "\<CR>")).' |  clip.exe')

nnoremap <leader>u :UndotreeToggle<CR>

tnoremap <leader>, <C-\><C-n><C-W>

let g:ale_linters = {'python': ['flake8 --ignore=E501']}
let g:ale_fixers = {'*': [], 'python': ['black']}
let g:ale_fix_on_save = 1

" MOVE AROUND WRAPPING
noremap <silent> k gk
noremap <silent> j gj
" noremap <silent> 0 g0
" noremap <silent> $ g$

" MOVE CODE BLOCKS
vnoremap < <gv
vnoremap > >gv

" FIND FILES
set path+=**

" TAG JUMP
command! MakeTags !ctags -R .

" FILE BROWSING
let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_browse_split = 4
let g:netrw_altv = 1
let g:netrw_winsize = 18
