# Ford Diagnostic Pro — Flutter + Android Bluetooth Classic

Aplicativo Android de diagnóstico OBD-II genérico, voltado ao **Ford New Fiesta SE 1.6 Sigma 2013/2014 PowerShift DPS6**.

## Funcionalidades implementadas

- Lista adaptadores Bluetooth **já pareados** pelo Android e conecta por RFCOMM SPP ao ELM327 azul.
- Inicialização ELM327, identificação (`ATI`), protocolo (`ATDP`), descoberta de PIDs genéricos suportados.
- Sensores genéricos: temperatura, RPM, velocidade, carga, temperatura de admissão e tensão da ECU quando anunciados.
- Leitura de DTCs genéricos modo 03; leitura de pendentes (07) e permanentes (0A), e consulta bruta de VIN (0902).
- Histórico persistente via `shared_preferences`, limitado a 1.000 entradas.
- Não implementa diagnóstico de módulos Ford TCM/ABS/BCM nem testes ativos.

## Consultar dados e histórico

Em **Diagnóstico → Dados OBD-II da central**, use **Ler todos os dados disponíveis**. O app consulta os identificadores anunciados para dados atuais (01), quadro congelado 00 (02), monitores (06) e identificação do veículo (09). Ele apresenta unidades para os PIDs decodificados e a resposta original do ELM327 para inspeção. A cobertura depende da central e do adaptador. Dados Ford proprietários e testes ativos estão fora dessa consulta.

Em **Histórico → Histórico de falhas**, busque por código, descrição ou data. As leituras de falhas confirmadas, pendentes e permanentes são gravadas no aparelho, incluindo a releitura após uma limpeza. O histórico de falhas guarda até 1.000 consultas, além dos registros antigos ainda disponíveis no histórico geral. Apagar falhas na central preserva essas consultas no aparelho.

## Preparar no VS Code (Windows)

**Pré-requisitos:** Flutter SDK no PATH, Android SDK, celular Android com depuração USB, cabo USB. Não precisa abrir emulador.

Abra um terminal PowerShell em uma pasta de trabalho, por exemplo `C:\Projetos`:

```powershell
flutter doctor
flutter create --org com.example ford_diagnostic_pro
```

**Depois** copie o conteúdo deste pacote para dentro da pasta `ford_diagnostic_pro`, substituindo os arquivos correspondentes (`lib`, `android/app/src/main`, `pubspec.yaml`, README e `.gitignore`). Não exclua os arquivos gerados por `flutter create`.

```powershell
cd ford_diagnostic_pro
flutter pub get
flutter devices
flutter run
```

O Android deve estar com o ELM327 pareado nas configurações do sistema antes de usar o botão **Pareados**. Teste com o carro parado, ignição ligada e o motor desligado no primeiro contato.

## Gerar APK

```powershell
flutter build apk --debug
```

Arquivo esperado no computador: `build\app\outputs\flutter-apk\app-debug.apk`. O APK de release requer configuração de assinatura para distribuição; `flutter build apk --release` pode ser usado para testes locais conforme configuração do Flutter.

## Subir ao GitHub

```powershell
git init
git add .
git commit -m "feat: primeiro diagnostico OBD2 Ford com ELM327"
git branch -M main
git remote add origin https://github.com/SEU_USUARIO/ford-diagnostic-pro.git
git push -u origin main
```

Crie o repositório vazio no GitHub antes de executar `git push`; substitua `SEU_USUARIO`. Não envie arquivos de assinatura, segredos nem histórico do veículo.

## Limitações importantes

- Este pacote é **código-fonte**, não APK pronto. Precisa do scaffold `flutter create` e compilação no seu computador.
- Ainda não houve teste físico com seu adaptador. Clones ELM327 variam em estabilidade e protocolos.
- Os módulos Ford proprietários podem exigir HS-CAN/MS-CAN e hardware compatível. Não garantimos acesso ao TCM com o ELM327 azul.
- O leitor DTC básico é preliminar e precisa ser validado com respostas reais antes de ser usado como diagnóstico conclusivo.
- O modo 04 apaga falhas genéricas, dados congelados e monitores de prontidão após confirmação e leituras de velocidade e RPM iguais a zero. Códigos permanentes podem continuar presentes. A limpeza não repara a causa da falha.
- Sem codificação, adaptação ou atuação.


## V0.4 — catálogo Ford e roteiro de implementação avançada
O aplicativo agora lista módulos Ford como **catálogo planejado** (não como módulos detectados). Consulte `docs/ARQUITETURA_FORD.md` para os requisitos técnicos de diagnóstico avançado. O acesso TCM/ABS/BCM ainda não foi implementado; esta versão não equivale ao FORScan.
