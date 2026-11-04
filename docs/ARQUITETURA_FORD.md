# Ford Diagnostic Pro — arquitetura para evolução estilo FORScan

## Veículo alvo
Ford New Fiesta SE 1.6 Sigma 2013/2014, transmissão PowerShift DPS6. Adaptador inicial: ELM327 Bluetooth Classic SPP azul.

## O que existe nesta versão
- Android Kotlin: pareamento, RFCOMM SPP, inicialização ELM327 e lista restrita de comandos de leitura.
- Flutter: dashboard, PIDs genéricos suportados, leitura DTC modo 03, respostas brutas modos 07/0A e 09 02, histórico local limitado a 1000 eventos.
- Catálogo de módulos Ford com avisos de compatibilidade. NÃO realiza comunicação UDS/ISO-TP com esses módulos.

## Camadas necessárias para alcançar recursos semelhantes ao FORScan
1. Transporte Bluetooth resiliente: timeouts, reconexão, cancelamento, buffer de quadros e detecção de clones.
2. CAN/ISO-TP: cabeçalhos AT SH, filtros, endereçamento físico/funcional, respostas multiquadro e flow control, apenas após validação por ECU.
3. Descoberta de ECU: identificação de rede, módulos realmente presentes, serviços suportados e matriz de permissões por módulo.
4. Diagnóstico Ford: DTCs por ECU com status e freeze frames, dados específicos de PCM/TCM/ABS/BCM/PSCM/IPC.
5. Telemetria: banco local estruturado, gráficos e exportação de sessões.
6. Serviços especiais e testes ativos: somente comandos específicos documentados e testados, com pré-condições (carro imobilizado, tensão estável, temperatura adequada), confirmação e possibilidade de abortar. Não habilitar por padrão.

## Restrições reais do ELM327 azul
- Bluetooth Classic SPP; Web Bluetooth BLE não substitui SPP.
- Adaptadores baratos podem não implementar comandos CAN avançados e não alcançar a rede MS-CAN.
- Não é possível garantir acesso completo a todos os módulos com esse hardware.
- Para diagnóstico ampliado Ford, um adaptador com HS-CAN/MS-CAN ou compatibilidade comprovada pode ser necessário.

## Segurança
NUNCA enviar comandos de apagamento DTC, reprogramação, ajuste de embreagens, atuação em freios, airbag ou direção sem implementação validada e controle explícito de segurança. As telas de catálogo não representam conexão nem suporte confirmado.
