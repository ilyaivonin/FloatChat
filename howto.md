Как пользоваться FloatChat

1. Установите llama-server: нажмите кнопку «Установить автоматически» справа от заголовка llama.cpp в настройках (или «Переустановить…», чтобы выбрать папку).
Настоятельно советуем установить llama-server заного, даже если он был установлен у вас ранее т.к. для работы с новыми моделями может понадобиться новая архитектура.
2. Скачайте модель: нажмите «Скачать модель…» и выберите одну из пяти моделей в списке либо укажите путь к своему файлу .gguf.
Реккомендуется использовать модели 4B и выше тк более маленькие модели часто "Галлюцинируют"
3. Нажмите «Применить и перезапустить» — llama-server запустится с выбранной моделью, контекстом и портом.
4. Напишите сообщение в чат — модель ответит локально на вашем Mac.

Подсказки
• Корзина в заголовке чата очищает историю сообщений.
• Кнопка с папкой рядом с «Скачать модель…» открывает папку с файлами .gguf.
• Threads, batch, контекст и порт спрятаны под пунктом «Тонкие настройки». Более точную настройку данных параметров вы можете подобрать в зависимости от конфигурации вашего оборудования.
• «Сбросить настройки» справа от «Поверх всех окон» возвращает стандартные значения: ctx 8192, port 4096, threads 4, batch 4.
• Изменения модели и тонких настроек применяются после «Применить и перезапустить».

How to use FloatChat

1. Install llama-server: Click the "Install Automatically" button to the right of the llama.cpp header in the settings (or "Reinstall..." to select a folder).
We strongly recommend reinstalling llama-server, even if you have it installed previously, as new models may require a different architecture.
2. Download a model: Click "Download Model..." and select one of the five models from the list, or specify the path to your .gguf file.
We recommend using models 4B and higher, as smaller models often "hallucinate."
3. Click "Apply and Restart" - llama-server will start with the selected model, context, and port.
4. Write a message in the chat - the model will respond locally on your Mac.

Tips
• The trash can in the chat header clears the message history.
• The folder button next to "Download model..." opens a folder containing .gguf files.
• Threads, batch, context, and port are hidden under "Fine Tuning." You can fine-tune these settings depending on your hardware configuration.
• "Reset settings" to the right of "Always on top" resets the default values: ctx 8192, port 4096, threads 4, batch 4.
• Changes to the model and fine tuning are applied after "Apply and restart."