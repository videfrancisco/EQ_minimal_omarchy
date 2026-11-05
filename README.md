# Equalizer (omarchy plugin)

Equalizador de 12 faixas (20 Hz – 20 kHz) para o Omarchy shell, com espectro de
áudio em tempo real (via [cava](https://github.com/karlstav/cava)) e presets de
curvas nomeados. Opera sobre o sink `Equalizer` do PipeWire, criado por
filter-chain, de forma que os ganhos sobrevivem a reinicializações.

Um botão `EQ` na barra do Omarchy abre o painel com:

- **Espectro ao vivo** de 32 barras (cava em modo raw, lendo o monitor da saída),
  com toggle para desligar o analisador quando não estiver em uso.
- **12 sliders de ganho** de −12 dB a +12 dB, com passos de 0,5 dB:
  low shelf em 40 Hz, bands peaking de 60 Hz a 14 kHz e high shelf em 16 kHz.
- **Presets**: salve a curva atual com um nome, recarregue com um clique e
  apague com o botão direito. Ficam em `~/.config/omarchy/eq-presets.json`.
- **Liga/desliga** do sink Equalizer e **reset** de todas as faixas.

## Instalação

```sh
omarchy plugin add https://github.com/videfrancisco/EQ_minimal_omarchy.git --enable
```

Depois habilite o widget na barra em **Settings → Shell → Bar**, ou rode:

```sh
omarchy plugin enable francisco.eq
```

## Remoção

Desligue o equalizador antes de remover, para o sink ser desfeito:

```sh
~/.config/omarchy/plugins/francisco.eq/scripts/eq.sh off
omarchy plugin remove francisco.eq
```

`off` remove o config `~/.config/pipewire/pipewire.conf.d/eq6.conf` e reinicia o
PipeWire. O plugin também guarda estado em `~/.config/omarchy/eq.json` e em
`~/.config/omarchy/eq-presets.json`; remova manualmente se quiser limpar as
curvas salvas.

## Dependências externas

- **PipeWire + pw-cli + pw-dump + jq** — essenciais (o sink do equalizador).
- **cava** — opcional; só o espectro ao vivo. Sem ele o painel mostra
  "Spectrum unavailable — install cava" e o resto funciona.
- `omarchy-shell` — fornecido pelo Omarchy.

## CLI do script

O mesmo script `eq.sh` funciona no terminal:

```sh
eq.sh status                      # estado atual em JSON
eq.sh set 3 -4.5                  # ganho da faixa 3 (160-320 Hz)
eq.sh reset                       # todas as faixas em 0 dB
eq.sh on | off                    # cria ou remove o sink Equalizer
eq.sh bands                       # tabela de faixas e frequências
eq.sh presets                     # nomes dos presets salvos
eq.sh preset-save Vocal           # salva a curva atual
eq.sh preset-load Vocal | preset-delete Vocal
eq.sh spectrum on | off           # preferência do analisador no painel
```

## Estrutura

| Arquivo | Papel |
| --- | --- |
| `manifest.json` | Manifest do plugin (schema 1, kinds `bar-widget` + `panel`) |
| `BarWidget.qml` | Botão `EQ` na barra do Omarchy shell |
| `Panel.qml` | Painel com espectro, sliders de 12 faixas e presets |
| `scripts/eq.sh` | Backend CLI: filter-chain do PipeWire, estado e presets |
| `scripts/cava.conf` | Config do cava em modo raw para o espectro |

## Licença

[MIT](LICENSE)
