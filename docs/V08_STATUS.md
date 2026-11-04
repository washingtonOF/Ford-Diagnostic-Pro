# Ford Diagnostic Pro V0.8 — publicações incrementais

## Publicado no GitHub
- lib/main.dart: atalhos de painel, indicadores em estado indisponível, descrições de DTC confirmados.
- lib/obd_v08.dart: decodificação genérica de DTC 03/07/0A, nível de combustível e estimativas por MAF.
- test/obd_v08_test.dart: testes iniciais de interpretação e cálculo.
- .github/workflows/ford-v08-apk.yml: testes e compilação APK debug.
- docs/design_v08/dashboard_preview.svg e splash_preview.svg: referências visuais.
- assets/images/ford_diagnostic_banner.png: banner já existente preservado.

## Ainda não publicado/integrado
- Correções nativas de Bluetooth ELM327 e comando 04 com confirmação.
- Interface de leitura dos modos 07 e 0A (módulo parser publicado, integração UI pendente).
- Cálculo contínuo de distância e consumo em sessões reais; calibração para gasolina/etanol.
- Gráficos e estatísticas completas de viagem.
- Exportação PDF.
- Temperatura do PowerShift e DTCs aprimorados do TCM (requerem identificação e validação do protocolo).
- Imagens PNG de prévia e ícone definitivo do pacote local (somente SVGs de referência estão no GitHub).
- Testes reais no Fiesta e confirmação de build APK.

**Aviso:** imagens conceituais não são capturas do APK; sensores não suportados não devem exibir números fictícios. O comando genérico 04 limpa informações de diagnóstico e readiness, requer confirmação explícita e validação em veículo parado.
