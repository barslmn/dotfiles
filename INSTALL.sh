#!/bin/sh

cd || exit
sudo apt install -y vim-gtk3 zsh fzf tmux git

git init
git remote add origin https://github.com/barslmn/dotfiles.git
git pull origin main

# get the latest relase of nnn
 wget -q -O- https://api.github.com/repos/jarun/nnn/releases/latest \
	| awk '/browser_download_url/ && /nnn-nerd-static/ {gsub(/\"/, ""); print $2}' \
	| wget -q -i- -O- \
	| tar xzf - -O | sudo tee /usr/local/bin/nnn > /dev/null \
        && sudo chmod +x /usr/local/bin/nnn

# zsh
sh -c "$(wget -q -O- https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"/themes/powerlevel10k
git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"/plugins/zsh-syntax-highlighting

# vim
mkdir -p "$HOME"/.vim/autoload \
	&& wget -q -O "$HOME"/.vim/autoload/plug.vim \
	https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
vim +PluginInstall +qall

# tmux
git clone https://github.com/gpakosz/.tmux.git
ln -s -f .tmux/.tmux.conf .
