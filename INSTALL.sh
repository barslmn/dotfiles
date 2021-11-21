#!/bin/sh

sudo apt install -y vim-gtk3 zsh fzf tmux git

# get the latest relase of nnn
 wget -q -O- https://api.github.com/repos/jarun/nnn/releases/latest \
	| awk '/browser_download_url/ && /nnn-nerd-static/ {gsub(/\"/, ""); print $2}' \
	| wget -q -i- -O- \
	| tar xzf - -O | sudo tee /usr/local/bin/nnn

# zsh
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"/themes/powerlevel10k
git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"/plugins/zsh-syntax-highlighting

# vim
curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
	https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
vim +PluginInstall +qall

# tmux
cd || exit
git clone https://github.com/gpakosz/.tmux.git
ln -s -f .tmux/.tmux.conf .
