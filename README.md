# OW Editor — app

App Flutter para enviar a gravação de uma partida, acompanhar a análise e
assistir aos vídeos gerados. **Mobile-first**, mas roda na web: em telas largas
o conteúdo para de esticar e fica centralizado em vez de virar uma linha
gigante.

> Todos os comandos abaixo assumem que você está **dentro de `frontend/`**.

---

## Rodando

```bash
flutter pub get
flutter run -d chrome        # ou: flutter run -d <seu-android>
```

Precisa do backend no ar. Suba com `cd ../backend && python tools/dev.py`.

## Compilando para produção

```bash
flutter build web --dart-define=API_BASE=
```

Com `API_BASE` **vazio**, o app chama a API em caminho relativo — aí o próprio
gateway serve o app em `/`, na mesma origem, e não há CORS envolvido nem
necessidade de recompilar para cada ambiente. O `docker-compose.yml` da raiz
monta `build/web` no gateway automaticamente.

Para apontar para um backend em outro host:

```bash
flutter build web --dart-define=API_BASE=https://meu-servidor.exemplo
```

## Testando

```bash
flutter analyze
flutter test
```

---

## Telas

| Arquivo | Tela |
|---|---|
| `screens/jobs_screen.dart` | lista de partidas, com status ao vivo enquanto houver job em andamento |
| `screens/new_job_screen.dart` | **fase 1**: escolher a gravação e ajustar as regras da análise. Nada de música aqui |
| `screens/job_detail_screen.dart` | progresso da análise, linha do tempo, o que dá para gerar, e o histórico de pedidos com os vídeos de cada um |
| `screens/generate_screen.dart` | **fase 2**: marcar as propostas, dar uma música **por vídeo** e recortar o trecho de cada uma |
| `screens/timeline_screen.dart` | **montagem manual**: pôr música e momentos na régua, cada um onde se quiser e do tamanho que se quiser |
| `screens/player_screen.dart` | player do clipe |

O app segue a divisão em duas fases do backend: primeiro a partida é analisada
e o job para em `ready`; a partir daí a tela de detalhe oferece *Gerar vídeos*
quantas vezes o usuário quiser, e cada pedido aparece no histórico com os seus
clipes. Proposta escolhida não se gasta: dá para gerar a mesma montagem de novo
com outra música.

`widgets/music_window.dart` opera sobre `ClipOptions`, que é **por vídeo** — é
o que permite músicas e durações diferentes no mesmo pedido. Proposta sem
música vira vídeo com o áudio original da partida, e a interface diz isso em
vez de deixar o usuário adivinhar.

### Texto que o sistema escreve

`rotulos.dart` é o diferencial deste editor, e ele não está no ffmpeg: está em
o editor **saber o que aconteceu no vídeo**. Para qualquer outro, o vídeo é um
retângulo de pixels sem história.

- **contador de eliminações** que sobe sozinho, cada número durando até o
  próximo corte de kill;
- **rótulos de rajada** com os nomes do jogo — `TRIPLE KILL`, não "3 kills".

Os dois saem como clipes de texto comuns: o gerador é um atalho, não uma
entidade nova. Texto entra numa camada nova quando só existe uma, porque texto
quase sempre vai por cima de imagem.

### Efeitos

O bloco escolhido tem um painel recolhido de efeitos: **velocidade**, **fades**
de entrada e saída, e **cor** (brilho, contraste, saturação). Fica recolhido
porque a maioria das montagens é corte seco, e um painel sempre aberto
empurraria a régua para fora da tela.

A velocidade não encolhe o bloco: ela muda quanto da gravação entra nele. Dois
segundos a 2× comem quatro segundos de partida, e continuam ocupando dois
segundos do vídeo.

Fades maiores que o clipe são encolhidos aqui, mantendo a proporção entre
entrada e saída — o servidor os recusaria, e descobrir isso só na hora de gerar
seria pior.

**Aproximar** é o *punch* na batida, em três botões: a lente fecha rápido e
afrouxa até o fim do bloco. Os pontos da animação são frações do clipe, então
esticar o bloco não desmancha o efeito.

**Congelar** e **de trás para frente** se excluem — ligar um desliga o outro,
que é o que se quis dizer ao ligar o segundo.

A **mistura** é da montagem inteira: com o jogo em zero a música toca sozinha;
acima disso o tiro aparece por baixo dela.

### Saída

O painel **Saída** não edita nada. Trocar 16:9 por 9:16 não move um clipe — muda
a janela por onde se olha para o mesmo trabalho, e por isso dá para ir e voltar
à vontade (e desfazer, como qualquer outra escolha).

Cinco formatos e três qualidades, e nada além disso: uma lista com toda
resolução que o H.264 aceita não ajuda ninguém a decidir. O resumo em cima diz o
que vai sair de verdade — tamanho, duração e um palpite de peso. É palpite
mesmo, e serve para responder "isso vai dar 8 MB ou 800?", que é a pergunta que
se faz antes de exportar.

**Preencher** ou **caber** só aparece quando a proporção pedida difere da
gravada: até lá não há o que decidir. E **só a seleção** exporta do primeiro ao
último bloco escolhido — para conferir uma emenda de dois segundos sem esperar
cinco minutos de vídeo.

A **marca d'água** sai da biblioteca: qualquer imagem que esteja lá, num dos
quatro cantos.

### Montagens, versões e predefinições

O título da tela é o **seletor de montagem**: numa partida com três, saber qual
está aberta importa mais do que ler "Montar vídeo" pela décima vez. Por ele se
troca de montagem e se começa outra; pelo menu vêm duplicar, renomear, apagar,
o histórico e as predefinições.

Trocar de montagem **limpa o histórico de desfazer**. Ele é a memória de uma
sessão de trabalho *numa* montagem — desfazer para dentro de outra apagaria o
que se acabou de abrir.

A primeira montagem só nasce quando há o que guardar: abrir o editor e fechá-lo
sem mexer em nada não deixa lixo na lista.

`receita.dart` é o aplicador de predefinições, e o caminho de volta. Aplicar uma
receita produz uma montagem comum — depois disso cada bloco se move e se apara
como qualquer outro. Ler uma receita a partir da montagem que está na tela usa a
**mediana** dos cortes, e não a média: um bloco esticado até o fim da música
puxaria a média para longe do que todos os outros são. E, se os cortes ocupam um
número redondo de batidas, é em batidas que o tamanho fica guardado — assim a
predefinição sobrevive a uma música de outro andamento.

### Biblioteca de mídia

A lateral tem duas abas: **Momentos**, que o sistema achou, e **Biblioteca**, o
que o usuário trouxe de fora — vídeo, imagem ou música. Elas ficam lado a lado
porque respondem à mesma pergunta: "o que eu ponho agora?".

Um item da biblioteca vira um clipe como qualquer outro. Imagem não tem duração
própria — quanto ela fica na tela é escolha da montagem —, e de um vídeo longo
se usa um pedaço, não ele inteiro.

**A música entra por aqui, e só por aqui.** Houve um painel só dela, e ter duas
portas para trazer a mesma coisa era o que fazia parecer que havia dois tipos de
som — com regras diferentes. `Track` e `Media` de áudio sempre foram a mesma
linha no banco (`Media.comoMusica` faz a ponte); agora são também o mesmo
caminho na tela.

Tirar da biblioteca um item que está na montagem é recusado: o clipe ficaria
órfão e o servidor rejeitaria o pedido.

### Camadas

A linha do tempo tem **camadas** empilhadas: a primeira da lista é o fundo, a
última fica por cima — a mesma ordem em que o servidor as desenha. Chamam-se
camadas, e não faixas, porque `Track` neste sistema já é a música enviada.

Na régua elas aparecem **invertidas**, e de propósito: a pista de cima é a
camada de cima, como em qualquer editor (`MusicTimeline.camadaDaLinha` faz a
conta). Sem isso, arrastar uma camada para o topo a mandava para trás de todas
as outras — o que só passou a doer quando reordenar virou gesto.

A ordem se muda arrastando o cabeçalho: há uma **alça** (arrasto imediato, para
o ponteiro) e o toque longo no cabeçalho inteiro, para o dedo. Reordenar é uma
edição como outra qualquer — muda o que aparece, e entra no desfazer.

O cabeçalho de cada uma fica **fora da rolagem** — ele é a referência, e precisa
continuar visível quando a régua anda. Nele: esconder, emudecer e travar.
Esconder e emudecer mudam o vídeo; travar é só a tela recusando editar.

A colisão passou a ser **por camada**. Dois clipes no mesmo instante em camadas
diferentes é justamente o que camada serve para fazer.

Arrastar um clipe para cima ou para baixo o leva para outra camada, mantendo o
instante — e recusa se o lugar já estiver ocupado lá, porque empurrá-lo para
outro instante seria mudar duas coisas quando se pediu uma. **A recusa fala**:
camada de som não recebe imagem, camada travada não recebe nada, e instante
ocupado é instante ocupado. Recusar calado é o pior dos dois mundos — o bloco
volta para o lugar e quem arrastou não sabe se o gesto não pegou ou se a
operação não era possível.

Uma camada é de **imagem** ou de **som** (`kind`), nunca das duas coisas: a de
som não desenha nada, e o que vai nela é música da biblioteca — veja *Música na
régua*. No cabeçalho ela aparece com a nota musical e sem o botão de esconder,
que não teria o que esconder.

O monitor não compõe: ele mostra um quadro. Então onde duas camadas se cobrem,
ele mostra a de cima (`clipesVisiveis`), que é o que o servidor vai desenhar por
último.

### A tela de montagem

O outro caminho: em vez de aceitar o palpite do sistema, o usuário monta. A
música sobe pela biblioteca — sem ouvi-la não há como decidir onde um corte cai —
e volta do servidor com duração, BPM, batidas e uma forma de onda já reduzida,
que é o que cada bloco de música desenha dentro de si em
`widgets/music_timeline.dart`. Os momentos da partida aparecem como fichas;
tocar numa põe o bloco na cabeça de leitura, arrastá-la põe onde se largou.

Depois disso é edição, com os três gestos de qualquer editor: arrastar o corpo
do bloco **move**, a borda direita **estica** e a esquerda **apara**. O ímã (no
topo da tela) gruda as bordas na batida mais próxima. Espaço deixado entre dois
blocos vira **tela preta**, com a música tocando se houver bloco de som ali — a
tela diz quanto, porque isso conta na duração do vídeo.

> **O arrasto que não arrastava.** A primeira versão aplicava `delta.dx` quadro
> a quadro em cima do valor atual. Com o ímã ligado o bloco já estava *sobre*
> uma batida, então cada passo de 3px virava 0,05 s e era grudado de volta na
> mesma batida: o bloco só saía do lugar num piparote forte o bastante para
> vencer a tolerância num único quadro. Agora cada gesto guarda de onde partiu e
> acumula o deslocamento inteiro, e o ímã decide sobre a intenção do arrasto, e
> não sobre um pixel. Os testes que travam isso arrastam em passos de 3px de
> propósito — `tester.drag` entrega o movimento em dois saltos grandes, e com
> saltos grandes até o código quebrado passava.

A tela tem layout de editor a partir de 900px de largura: prateleira de momentos
à esquerda (cada um com o quadro da partida naquele instante), monitor
redimensionável em cima e a régua embaixo. Abaixo dessa largura vira uma coluna
só, com a prateleira depois da régua — o app continua servindo num celular.

Dentro de cada bloco há uma **marca** no ponto em que a jogada acontece
(`marcaDoMomento`). Um bloco é um trecho, o momento é um instante dentro dele; o
que se alinha com a percussão é a jogada, e a borda do corte pode estar meio
segundo antes dela. Aparar o bloco pela esquerda move a marca — ela é desenhada
a partir do corte, nunca deduzida.

A **grade de batidas** é ajustável: deslocamento, densidade (½ / 1× / 2×) e
grudar no compasso. O detector de ritmo erra de duas maneiras previsíveis —
pega o contratempo, ou conta o dobro/metade das batidas —, e nenhuma delas se
conserta arrastando bloco por bloco: quem está errada é a régua. Os ajustes
ficam no rascunho e se desfazem como qualquer edição.

A régua é o tempo do **vídeo que vai sair**: o instante zero é o primeiro quadro
dele. A música mora dentro dessa escala, em blocos.

### Música na régua

A música vive numa **camada de som** — uma camada `audio`, que não desenha nada e
não entra no empilhamento visual. Os blocos dela são clipes comuns com `mediaId`
apontando para um item da biblioteca, e por serem clipes comuns já sabem cortar,
mover, aparar e duplicar: não houve objeto novo a inventar, só a música a deixar
de ser especial.

`porMusica` põe um bloco na cabeça de leitura (ou onde o dedo largou); onde já há
música, o bloco novo entra **depois** do que está lá, em vez de empurrar o que já
foi encaixado na batida. Sem camada de som, ela nasce — pedir música e receber um
pedido de camada seria burocracia.

Houve uma **faixa contínua** que tocava por baixo de tudo e não se cortava.
`montagemDoRascunho` ainda a lê: `trackId` + `musicStartS` viram um bloco que
começa onde ela entrava e cobre o vídeo inteiro, e `toJson` nunca mais escreve os
dois campos — mandá-los de volta criaria uma segunda música por baixo da que já
virou bloco.

`clipesVisiveis` pula as camadas de som — considerá-las apagaria o vídeo que está
por baixo — e `moverParaCamada` recusa o trânsito entre camada de som e de
imagem, que o servidor recusaria de todo jeito.

A **grade de batidas** passa a ser a da música que está tocando sob a cabeça de
leitura, trazida para o tempo do vídeo descontando o pedaço da faixa que ficou de
fora. Um vídeo com duas faixas tem dois andamentos, e grudar na batida da outra
seria pior do que não grudar em nada.

O painel do bloco selecionado muda de assunto quando o bloco veio da biblioteca:
diz o nome do arquivo, e no caso da música de que ponto dela o pedaço saiu, chama
o deslocamento de "trecho da música" e some com os efeitos — zoom, congelar e cor
não têm sobre o que agir num bloco que não desenha nada.

### A jogada dentro do bloco

`momentoNoVideo` diz onde a jogada cai no vídeo: `atS + (sourceT - startS)`. É
com ela que três coisas funcionam.

`alinharMomento` põe essa jogada num instante pedido, e tem **dois caminhos**:
andar com o bloco (preserva o embalo, muda quando a cena aparece) ou deslizar o
trecho dentro dele (preserva a posição na régua, muda qual pedaço da gravação
aparece). O segundo é o que sobra quando os vizinhos não deixam o bloco passar —
o caso comum numa montagem de blocos colados —, e o resultado diz qual dos dois
aconteceu, para a tela contar.

O ímã de `mover` disputa entre três candidatos: começo, fim e jogada. Só entram
os que grudaram em alguma batida, e vence o mais perto de onde o dedo largou.

E a marca desenhada dentro do bloco acende quando a jogada está sob a cabeça de
leitura — meio quadro de tolerância, porque alinhar é decisão de montagem e não
medida de precisão infinita.

### O texto no monitor

O texto existia na régua e no vídeo gerado, e em lugar nenhum entre os dois:
para saber onde a frase ia parar era preciso gerar o vídeo. O monitor agora
desenha os clipes de texto ativos com a **mesma conta do servidor** — corpo em
fração da altura do quadro, posição em metades de quadro a partir do centro,
contorno incluído — e arrastá-los ali escreve `transform.x/y`
(`posicionarNoQuadro`).

Dois detalhes que custaram depuração:

- os avisos do monitor (tela preta, carregando) ficam em `IgnorePointer`. Eles
  moram no meio do quadro, que é justamente onde o texto costuma estar, e um
  `CustomPaint` responde `true` ao teste de acerto por padrão — o spinner
  roubava o arrasto da frase;
- o gesto usa `DragStartBehavior.down` e soma `d.delta`. Com o padrão (`start`)
  o deslocamento gasto para vencer o slop é descartado, e um arrasto entregue de
  uma vez só — dedo rápido, ou um teste — não produz update nenhum.

### Arrastar da prateleira para a régua

Clicar num momento ou num item da biblioteca põe o bloco na cabeça de leitura —
serve para quem monta na ordem. Arrastar põe **onde o dedo largou**, na pista em
que largou.

Os dois lados são `Draggable<ArrastoParaARegua>` com `affinity: Axis.horizontal`
(a prateleira continua rolando na vertical) e `pointerDragAnchorStrategy`: o
fantasma fica pendurado no dedo, e não no ponto do cartão em que se pegou, porque
`DragTargetDetails.offset` é o canto do fantasma — sem isso o bloco cai meio
cartão à esquerda de onde se soltou.

A régua é um `DragTarget` que converte a posição global em (instante, camada) e
desenha um retângulo do tamanho do bloco antes de soltar. Largar música numa
pista de imagem não é erro: quer dizer "neste instante", e ela vai para a camada
de som. Largar um momento numa camada de som, sim.

### O teclado

Os atalhos são de uma tecla só onde isso faz o editor voar: **S** divide no
cursor, **espaço/K** toca, **J/L** andam, **[** e **]** aparam as pontas,
**Delete** apaga o bloco escolhido. Ctrl/Cmd cobrem desfazer, copiar, colar,
duplicar e selecionar tudo — os dois registrados, para não haver um "por que não
funciona aqui".

Enquanto alguém escreve num campo, **não há atalho registrado** — o mapa de
`bindings` fica vazio. A diferença entre isso e "um atalho que não faz nada" é o
ponto todo: o `CallbackShortcuts` marca a tecla como tratada assim que algum
atalho a aceita, faça ele o que fizer, e no navegador tecla tratada vira
`preventDefault`. A primeira tentativa de conserto calou a ação e manteve o
registro; o resultado foi o pior dos dois mundos — o "s" parou de dividir o
corte e continuou não sendo escrito.

Duas peças completam:

- **quem tem o foco** vem de `findAncestorStateOfType<EditableTextState>()` a
  partir do foco primário. A busca pelo *widget* `EditableText` funcionava nos
  testes e falhava no build de release do navegador, onde os nomes de tipo são
  minificados — e falhar ali é falhar onde o usuário está;
- **como o foco volta**: `onTapOutside` nos campos devolve o foco à montagem.
  Nada tira o foco de um `TextField` por conta própria, então sem isso um toque
  no campo deixava "S" e Delete mortos pelo resto da sessão.

### O relógio

O relógio é o **vídeo**, e não a música. Enquanto a faixa era contínua o player
dela podia mandar no tempo — havia som do primeiro ao último quadro. Com blocos
que entram e saem não há player nenhum tocando o vídeo inteiro, então a cabeça de
leitura tem um `Timer.periodic` próprio e a música segue-a: `_acertarAMusica`
carrega o bloco que está sob ela e busca o ponto correspondente.

Enquanto um bloco toca, **ele** é o relógio: a posição do player vira a posição
da cabeça de leitura, porque é esse som que o usuário está ouvindo e puxá-lo de
volta a cada deriva daria um soluço audível. Se o player se perde de vez (mais de
meio segundo), o relógio segue sem ele.

A montagem é salva sozinha no servidor um segundo e meio depois da última
mexida, e a mais recente é recuperada ao abrir a tela — um `Job` traz as suas
`montages`. O indicador no topo diz quando o trabalho está guardado, porque sem
sinal ninguém sabe se pode fechar a aba.

O monitor abre o **proxy** da partida — a cópia reduzida que sai da mesma
decodificação dos recortes — e cai na gravação original só nas partidas
analisadas antes dele existir (`job.monitorUrl`). Foi buscar dentro do arquivo
de meio giga que derrubava o player.

Dentro de cada bloco é desenhada a **onda do áudio da partida**: o job traz a
onda inteira e o bloco recorta o pedaço que mostra, então aparar ou esticar muda
o desenho sozinho. É por ela que se casa o tiro com a batida.

`widgets/preview_player.dart` é o monitor: abre a gravação original e busca
dentro dela o instante que a cabeça de leitura pede, em vez de renderizar. Onde
não há bloco, tela preta, com um rótulo dizendo que é isso mesmo que vai sair —
preto sem explicação parece defeito. As buscas são limitadas a uma a cada 60 ms
enquanto se arrasta o cursor, porque cada uma é uma requisição `Range` no
arquivo da partida.

As contas ficam em `montage.dart`, longe de qualquer widget: onde um bloco pode
cair, quanto pode durar, onde o corte começa na gravação para a jogada cair a
70% dele. É a parte que tem resposta certa, e é a parte testada — `montage.dart`
é o espelho de `owcore/timeline.py` no servidor, e os dois têm de concordar.

> **O monitor que morria.** O elemento de vídeo do navegador às vezes falha ao
> servir uma gravação grande por `Range` com muitas buscas seguidas, e nada no
> `video_player` avisa além de `value.hasError`. Sem vigiá-lo, o monitor ficava
> preto até a página ser recarregada — e recarregar custava a montagem inteira.
> Agora ele é reaberto sozinho no mesmo ponto, até quatro vezes, e as buscas são
> serializadas com folga de 120 ms.
>
> O player de áudio usa `video_player` apontado para a URL da música. Se ele
> não inicializar (o formato depende do navegador), a tela **continua
> funcionando**: a onda e as batidas já estão desenhadas, e é por elas que se
> encaixa o corte. A tela avisa em vez de travar. Esse caminho de falha não tem
> teste automatizado — depende do codec do navegador.

### Estado e histórico

`montage_state.dart` guarda a montagem inteira num objeto **imutável**, e toda
operação recebe um estado e devolve outro. Desfazer vira trocar de referência.

> A V1 guardava uma `List<TimelineCut>` e a alterava no lugar, em trinta pontos
> diferentes. Funcionava para seis operações e não sobreviveria a vinte: não
> havia como desfazer nada, porque não havia "antes" — o estado anterior era
> sobrescrito no instante em que o novo nascia.

Um arrasto produz um estado por quadro, então o histórico agrupa por **gesto**:
`abrirGesto()` no começo do arrasto, `fecharGesto()` ao soltar, e enquanto ele
está aberto o topo da pilha é substituído em vez de crescer. Sem isso, desfazer
andaria um pixel de cada vez.

Cada bloco tem um `id` local, que **não vai para o servidor**. Índice não serve
de identidade: apagar um bloco desloca os seguintes, e uma seleção múltipla ou
um passo de desfazer passariam a apontar para o vizinho.

Seleção e título mudam por `substituir()`, não por `aplicar()` — desfazer tem de
voltar uma *edição*, não uma mudança de foco.

`api.dart` concentra o cliente REST e os modelos. O upload é feito em
**streaming** (`readAsByteStream`), nunca carregando o arquivo inteiro na
memória — uma gravação de partida não caberia na RAM de um celular.

`widgets/download.dart` concentra os downloads, com implementação escolhida na
compilação:

- **web** (`download_web.dart`): um `<a download>` clicado por código, via
  `package:web`. Sem plugin nenhum — o servidor responde com
  `Content-Disposition: attachment`, então o nome vem de lá e a página fica onde
  está;
- **celular/desktop** (`download_io.dart`): `url_launcher` abrindo o navegador
  do sistema, que é quem sabe salvar arquivo.

> **Por que a web não usa `url_launcher`.** Este botão quebrou duas vezes por
> causa dele. Primeiro porque a URL vinha relativa (`/api/...`) e o launcher
> exige esquema — resolvido com `absoluteUrl`, que resolve contra `Uri.base`.
> Depois com `MissingPluginException`, mesmo com o plugin presente no
> `web_plugin_registrant.dart` e após `flutter clean`. Baixar um arquivo da
> mesma origem não precisa de plugin: o navegador faz isso nativamente, e é o
> que o app passou a fazer.
>
> Vale saber: os testes de widget rodam na VM, ou seja, no caminho
> `download_io.dart`. **O caminho web não é coberto por teste automatizado** —
> foi verificado no Chrome, conferindo o arquivo no disco.

`widgets/highlight_style.dart` é onde cada tipo de highlight e de evento ganha
ícone, cor e nome em português, para todas as telas falarem a mesma língua.

---

## Contrato com o backend

O app depende só do REST do gateway, navegável em
<http://localhost:8000/docs>:

| Rota | Para quê |
|---|---|
| `POST /api/jobs` | multipart com `video` e `params` (JSON) — só a gravação |
| `GET /api/jobs` | lista, para a tela inicial |
| `GET /api/jobs/{id}` | detalhe com eventos, detectores, propostas, músicas e pedidos |
| `DELETE /api/jobs/{id}` | remove a partida |
| `POST /api/jobs/{id}/tracks` | multipart com `audio` — manda o sistema ouvir uma música |
| `GET /api/tracks/{id}` | a música analisada: duração, BPM, batidas e forma de onda |
| `GET /api/tracks/{id}/audio` | o áudio, com `Range`, para o player tocar e buscar |
| `POST /api/jobs/{id}/renders` | multipart: `selections` (JSON) + um `music_<proposal_id>` por vídeo que leva trilha, e/ou `timelines` (JSON) com as montagens manuais |
| `GET /api/renders/{id}` | andamento e clipes de um pedido |
| `DELETE /api/renders/{id}` | apaga o pedido; as propostas ficam |
| `GET /api/clips/{id}/video` | vídeo, com suporte a `Range` para o player buscar |
| `GET /api/clips/{id}/thumb` | miniatura |
| `GET /api/clips/{id}/cortes.zip` | os cortes daquela montagem |
| `GET /api/jobs/{id}/cortes.zip` | pacote da partida: vídeos finais + todos os cortes |
