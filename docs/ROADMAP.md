# Roadmap

1. **Conectividade (implementada, a validar):** Bluetooth Classic SPP, comandos AT, erros e timeouts.
2. **OBD2 genérico (parcial):** PIDs, DTCs, VIN, freeze-frame, monitores e protocolos. Melhorar parser de respostas multi-frame.
3. **Histórico (parcial):** banco SQLite com sessões, gráficos e exportação CSV/PDF.
4. **Ford (planejado):** identificar redes HS-CAN/MS-CAN e módulos PCM, TCM DPS6, ABS, BCM, PSCM e IPC; usar apenas comandos documentados/validados.
5. **Testes seguros (planejado):** monitoramento passivo primeiro; testes ativos somente com protocolo confirmado, veículo parado e controles específicos.
6. **Qualidade:** testes unitários, testes em aparelho Android e revisão de falhas reais.
