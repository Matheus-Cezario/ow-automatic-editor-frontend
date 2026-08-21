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
| `screens/timeline_screen.dart` | **montagem manual**: ouvir a música e pôr cada momento onde se quiser, do tamanho que se quiser |
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

### A tela de montagem

O outro caminho: em vez de aceitar o palpite do sistema, o usuário monta. A
música sobe primeiro — sem ouvi-la não há como decidir onde um corte cai — e
volta do servidor com duração, BPM, batidas e uma forma de onda já reduzida,
que é o que `widgets/music_timeline.dart` desenha. Os momentos da partida
aparecem como fichas; tocar numa põe o bloco onde a música estiver.

Depois disso é edição: arrastar o bloco move o corte, arrastar a borda direita
muda a duração, e o ímã (no topo da tela) gruda as bordas na batida mais
próxima. Espaço deixado entre dois blocos vira **tela preta com a música
tocando** — a tela diz quanto, porque isso conta na duração do vídeo.

As contas ficam em `montage.dart`, longe de qualquer widget: onde um bloco pode
cair, quanto pode durar, onde o corte começa na gravação para a jogada cair a
70% dele. É a parte que tem resposta certa, e é a parte testada — `montage.dart`
é o espelho de `owcore/timeline.py` no servidor, e os dois têm de concordar.

> O player de áudio usa `video_player` apontado para a URL da música. Se ele
> não inicializar (o formato depende do navegador), a tela **continua
> funcionando**: a onda e as batidas já estão desenhadas, e é por elas que se
> encaixa o corte. A tela avisa em vez de travar. Esse caminho de falha não tem
> teste automatizado — depende do codec do navegador.

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
