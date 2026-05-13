if status is-interactive
    set -gx EDITOR hx
    set -gx VISUAL hx
    set -gx TERMINAL kitty
    set -gx BROWSER zen-browser

    fish_add_path $HOME/.local/bin

    alias ls="eza --icons"
    alias ll="eza -lah --icons"
    alias la="eza -a --icons"
    alias lt="eza --tree --level=2 --icons"
    alias cat="bat"
    alias c="clear"
    alias ff="fastfetch"
    alias y="yazi"
    alias g="git"
    alias v="hx"
end

if command -q zoxide
    zoxide init fish | source
end
