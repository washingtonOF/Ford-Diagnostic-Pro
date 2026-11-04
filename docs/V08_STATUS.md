# Ford Diagnostic Pro V0.8 — estado real (04/11/2026)

## Código publicado na branch main
- pubspec.yaml versão 0.8.0+8, dependências pdf e printing.
- lib/main.dart: painel de atalhos, banner existente, lista de falhas 03/07/0A, descrição e cópia de pesquisa Google, limpeza genérica 04 com confirmação e releitura, descoberta PIDs, estatísticas de viagem e gráficos de 60 leituras, exportação PDF.
- lib/obd_v08.dart: decodificação genérica DTC e funções de combustível/MAF.
- android/app/src/main/kotlin/br/com/forddiagnosticpro/app/MainActivity.kt: RFCOMM Bluetooth pareado, comando 04 permitido e timeout aumentado.
- test/obd_v08_test.dart: testes básicos.
- .github/workflows/ford-v08-apk.yml: testes e build APK debug com artifact.
- docs/design_v08/*.svg: duas imagens conceituais; assets/images/ford_diagnostic_banner.png: imagem real existente preservada.

## Pendências e limitações
- Build e testes automatizados: workflow enviado, execução/conclusão ainda não verificadas. NÃO há APK validado.
- Teste Bluetooth e leitura/limpeza reais no Fiesta: exige aparelho Android, ELM327 e carro.
- Parser CAN: necessita validar ISO-TP, quadros multi-linha e headers; resultados de DTC não devem ser usados como diagnóstico definitivo sem confirmação.
- Temperatura da transmissão PowerShift e DTCs aprimorados TCM: não implementados. Sem PID Ford validado, exibir indisponível.
- Consumo por MAF é aproximação para gasolina e precisa de calibração para etanol/flex; distância é integrada das amostras de velocidade e pode perder trechos.
- Imagens de referência SVG publicadas; os PNGs conceituais de dez telas e ícone definitivo ainda não foram incorporados aos assets de execução.
- A pesquisa Google é copiada para a área de transferência, não aberta diretamente.
- O comando 04 não é equivalente a limpar falhas específicas do TCM; apaga monitores readiness/freeze frame. Use apenas parado, com confirmação.

## Como obter APK quando workflow concluir
Abra GitHub > Actions > Ford Diagnostic Pro V0.8 - Testes e APK > execução concluída > Artifacts > Ford-Diagnostic-Pro-V08-debug.

## Atualização incremental de indicadores
- Painel agora apresenta nível de combustível, distância e consumo quando dados válidos estão disponíveis; caso contrário indica indisponível.
- A seleção gasolina/etanol modifica a estimativa MAF, mas não substitui calibração real nem cobre misturas flex.
- O workflow inclui flutter analyze, flutter test e flutter build apk --debug; o resultado de execução ainda não foi confirmado nesta conversa.

## Publicação de identidade Android e proteção adicional
- android/app/src/main/res/drawable/ford_launcher_icon.xml: ícone vetorial azul-escuro e azul-ciano, integrado ao AndroidManifest.
- android/app/src/main/res/drawable/launch_background.xml: fundo de abertura escuro com símbolo do aplicativo.
- lib/main.dart: limpeza modo 04 exige tanto velocidade zero quanto RPM zero informados pelo veículo; qualquer leitura ausente bloqueia.
- Não confundir ícone vetorial integrado com PNG definitivo: PNGs do pacote de referência ainda não foram publicados no repositório.
- Ainda faltam testes físicos no veículo, confirmação do workflow APK e acesso TCM proprietário validado.
