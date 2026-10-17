# WakeFabio (iOS 26.0+) ⏰

O **WakeFabio** é um projeto de despertador inteligente em desenvolvimento para iOS, focado na resolução de missões (com prioridade ao Código QR / de Barras) e checagem anti-sono (**Wake Up Check**), integrando-se com a framework nativa **AlarmKit** da Apple.

---

> Estado: as correções de integração e compilação foram revistas no Windows. Ainda é necessário executar o workflow macOS e testar no iPhone; este repositório não comprova um IPA compilado ou um despertador validado.

### Correções de recuperação e interface

- A interface reavalia as ocorrências na fila principal depois da transação de gravação, evitando reentrar no armazenamento durante a publicação.
- O editor mantém o rascunho aberto se guardar ou agendar falhar. Uma edição ativa prepara o novo par de alarmes antes de substituir o anterior; a configuração e a ocorrência confirmadas são gravadas em conjunto.
- As substituições interrompidas mantêm os IDs necessários para recuperação na próxima abertura. Se a recuperação falhar, o erro permanece visível e os IDs são conservados.
- Concluir uma missão manda parar explicitamente o toque atual no AlarmKit, usando `stop` para o principal semanal e cancelando apenas os resgates respetivos.
- Repetir uma operação de conclusão reutiliza o resgate preparado; uma verificação já expirada recebe uma nova janela futura.
- Foram acrescentados sete testes de regressão. A execução XCTest e a confirmação destes comportamentos no iPhone continuam pendentes do ambiente Apple.

## 🏗️ Arquitetura e Princípios de Engenharia

1. **AlarmKit Oficial (iOS 26+):** Utiliza as APIs oficiais da Apple (`AlarmManager`) para registo de alarmes ao nível do sistema operativo, permitindo disparar mesmo com o aparelho bloqueado, em modo Silencioso ou com Foco (Não Incomodar) ativo.
2. **Sem Truques Frágeis:** Eliminação total de loops de áudio silencioso em segundo plano (*keepalive*) e hacks de `MPVolumeView`. Notificações locais comuns são utilizadas apenas como complemento informativo e nunca como substituto de alarmes.
3. **Resgate Pré-Agendado contra Paragem Nativa:** 
   > [!IMPORTANT]
   > No ecossistema iOS, nenhuma aplicação de terceiros tem permissão para bloquear o botão nativo "Parar" do sistema no ecrã de bloqueio. O utilizador pode parar o alarme diretamente pelo sistema sem resolver a missão. 
   > Para contornar esta limitação, o WakeFabio pré-agenda um **Alarme de Resgate** (+3 minutos após o disparo) com identificador isolado *antes* de depender de execução futura. Se a missão for concluída dentro da aplicação, o resgate é imediatamente cancelado; se o utilizador parar o alarme nativo e voltar a dormir, o resgate tocará.
4. **Wake Up Check Resiliente:** O tempo restante não depende de um timer volátil da interface (`Timer`), mas sim de timestamps absolutos (`checkAt` e `responseDeadline`). Um alarme de emergência no AlarmKit é pré-agendado para o `responseDeadline` antes de iniciar a contagem.
5. **Persistência Atómica e Versionada:** Dados guardados em formato JSON versionado (`schemaVersion: 1`) no diretório `Application Support/WakeFabio/wakefabio_store.json`, com escritas atómicas que protegem contra ficheiros corrompidos em caso de encerramento inesperado.
6. **Desacoplamento de Canais de Áudio:** Três instâncias separadas de áudio no `AudioAlarmManager`: canal contínuo de alarme (loop infinito), canal de efeitos sonoros (SFX one-shot) e canal de pré-escuta de toques no editor.

---

## 🛠️ Ciclo de Desenvolvimento (Windows + GitHub Actions + iPhone)

### 1. Edição e Verificação no Windows
Como o desenvolvimento local é realizado em Windows, as alterações de código, lógica de negócio e testes estruturais são feitos diretamente nesta máquina. A compilação e empacotamento do binário nativo iOS são delegados ao GitHub Actions com runners macOS.

### 2. Compilação no GitHub Actions
O repositório inclui o fluxo automatizado em `.github/workflows/build-ios.yml`:
- **Runner:** macOS com ambiente Xcode SDK 26+.
- **Comandos:** Gera o projeto e o scheme de testes com XcodeGen a partir de `project.yml` (o script `generate_project.rb` é apenas um atalho para o mesmo gerador), exige Xcode/SDK iOS 26+, corre testes unitários num simulador instalado e executa `xcodebuild` para `iphoneos Release` com `-derivedDataPath build`.
- **Artefacto Gerado:** `WakeFabio-unsigned.ipa` disponibilizado para transferência na secção **Artifacts** do GitHub Actions.
- **Quotas de Execução:** Em repositórios privados, contas gratuitas do GitHub possuem 2.000 minutos/mês (runners macOS possuem multiplicador de 10x de consumo). Repositórios públicos contam com execução sem débito de minutos da quota básica, sujeitos aos limites de concorrência da plataforma.

---

## 📲 Instalação no iPhone (Sideloading e Assinatura Pessoal)

> [!WARNING]
> O ficheiro `WakeFabio-unsigned.ipa` gerado pelo CI **NÃO É ASSINADO** e não pode ser instalado diretamente sem uma etapa de assinatura local. Nunca insira credenciais Apple ID no chat ou em scripts de terceiros não verificados.

### Métodos de Instalação Recomendados:

#### Opção A: Sideloadly (Windows)
1. Instale o [Sideloadly](https://sideloadly.io/) no seu computador Windows.
2. Certifique-se de ter o iTunes e iCloud (versões normais da Apple, não da Microsoft Store) instalados.
3. Conecte o seu iPhone ao PC via cabo USB e desbloqueie o ecrã.
4. Descarregue o `WakeFabio-unsigned.ipa` dos Artefactos do GitHub.
5. Arraste o ficheiro `.ipa` para o Sideloadly, insira o seu Apple ID pessoal e prima **Start**.

#### Opção B: AltStore Classic (Windows)
1. Instale o [AltServer](https://altstore.io/) no Windows.
2. Conecte o iPhone por cabo e selecione **Install AltStore > Seu iPhone**.
3. No iPhone, abra o AltStore, aceda à aba **My Apps**, toque em **+** e selecione o `WakeFabio-unsigned.ipa`.

### Configurações Necessárias no iPhone:
1. **Modo de Programador (Developer Mode):**
   - No iPhone, aceda a **Definições > Privacidade e Segurança > Modo de Programador** e ative a opção (o dispositivo irá reiniciar).
2. **Confiança no Certificado:**
   - Aceda a **Definições > Geral > Gestão de Dispositivos e VPN**, selecione o seu Apple ID e prima **Confiar**.
3. **Validade de 7 Dias:**
   - Contas gratuitas da Apple emitem certificados válidos por 7 dias. Para manter a aplicação ativa, basta reconectar o iPhone ao AltServer/Sideloadly semanalmente para renovar a assinatura sem perda de dados.
4. **Permissões Obrigatórias:**
   - Ao abrir pela primeira vez, autorize o **AlarmKit** e o acesso à **Câmara** para a leitura do Código QR.

---

## 🧪 Matriz de Testes Físicos (Hardware iPhone Real)

| # | Cenário | Ação do Teste | Comportamento Esperado |
|---|---|---|---|
| **01** | **Aplicação Aberta (Foreground)** | Ativar alarme para 1 minuto no futuro com a app visível. | Ao chegar à hora, a tela de missão abre imediatamente e o alarme toca em loop contínuo. |
| **02** | **Aplicação em Background** | Ativar alarme, sair para o ecrã inicial do iOS. | O alarme do AlarmKit dispara com som na hora exata. Tocar na notificação abre a app diretamente na missão. |
| **03** | **Encerramento Forçado (Force Quit)** | Ativar alarme e fechar a app na multitarefa (deslizar para cima). | O alarme do sistema continua registado no AlarmKit e dispara na hora programada. |
| **04** | **Ecrã Bloqueado (Lock Screen)** | Bloquear o iPhone e aguardar o horário. | O ecrã acende com o alerta de ecrã inteiro do alarme e toca alto. |
| **05** | **Modo Silencioso Ativo** | Colocar a chave física/botão de ação em Silencioso. | O AlarmKit ignora o modo silencioso e reproduz o som do alarme em volume normal. |
| **06** | **Modo Foco / Não Incomodar** | Ativar o Foco "Não Incomodar" ou "Sono". | O alarme transpassa o Foco sem ser silenciado. |
| **07** | **Paragem Nativa sem Missão** | Quando o alarme tocar, carregar em "Parar" no ecrã de bloqueio e voltar a dormir. | Como a app não foi aberta para resolver a missão, o **Alarme de Resgate** (+3 min) dispara no sistema. |
| **08** | **Missão QR Code Correto** | Escanear o código exatamente registado no editor. | Emite som de sucesso (`wordbeat_success`), silencia o alarme e desativa o resgate. |
| **09** | **Missão QR Code Errado** | Escanear um código de barras diferente da referência. | O alarme continua a tocar; a interface exibe aviso vermelho e emite som de erro. |
| **10** | **Câmara Negada / Sem Permissão** | Negar o acesso à câmara nas Definições do iOS. | A app apresenta ecrã explicativo com atalho para as Definições do iOS. |
| **11** | **Wake Up Check Ignorado** | Resolver a missão, fechar a app e ignorar a notificação de checagem. | Ao atingir o `responseDeadline`, o alarme de emergência pré-agendado no AlarmKit dispara com som alto. |
| **12** | **Wake Up Check Confirmado** | Abrir a notificação e carregar em "ESTOU ACORDADO". | O alarme de emergência é cancelado e o ciclo do alarme é finalizado com sucesso. |
| **13** | **Reinício do Dispositivo (Reboot)** | Reiniciar o iPhone após agendar alarmes. | Os alarmes permanecem salvos no disco em `Application Support` e ativos no sistema. |
| **14** | **Recorrência Semanal** | Configurar alarme de Seg a Sex e concluir a ocorrência de hoje. | A próxima ocorrência é calculada e re-agendada para o dia útil seguinte. |
| **15** | **Edição e Cancelamento** | Desativar o toggle ou apagar um alarme na lista. | O alarme principal e o alarme de resgate correspondentes são cancelados sem deixar alarmes órfãos. |
| **16** | **Expiração dos 7 Dias** | Passados 7 dias da instalação gratuita. | O iOS impede a abertura até ser renovado via AltServer/Sideloadly (sem perda de configurações). |

---

## 🔒 Auditoria de Ficheiros de Som e Licenciamento

Os ficheiros de áudio incluídos em `WakeFabio/Resources/Sounds/` permanecem salvaguardados localmente no disco para referência e desenvolvimento, mas foram explicitamente excluídos do bundle por omissão no `project.yml` até confirmação de licenciamento. A aplicação e o `AudioAlarmManager` utilizam nativamente alertas sonoros e vibrações do sistema operativo via `AudioServicesPlaySystemSound` como fallback seguro e totalmente funcional.

---

## 🚦 Estado de Compilação e Testes (Declaração Transparente)

- **Ambiente Local Windows:** A compilação via `xcodebuild` e a execução da framework `XCTest` não estão disponíveis no Windows. Todos os ficheiros Swift, intents, vistas e testes foram atualizados com tratamento estrito de exceções (`try/catch`), rollback atómico, prevenção de concorrência e isolamento do modo de teste.
- **Validação Remota e Hardware:** A compilação do binário unsigned e a execução dos testes no simulador dependem do runner macOS no GitHub Actions. A validação em hardware físico iPhone com iOS 26 permanece pendente. A aplicação não é dada como concluída até à execução real no dispositivo alvo.
