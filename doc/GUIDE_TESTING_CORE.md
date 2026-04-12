# Тестирование модуля i2c_master_core — подробное руководство

## 1. Контекст: мы написали первый модуль, что дальше?

Вы только что спроектировали и реализовали `i2c_master_core` — ядро I2C мастер-контроллера. Это первый и самый важный модуль всего проекта. Он умеет формировать START, STOP, RESTART на шине, побитно передавать и принимать байты, обрабатывать ACK/NACK, ожидать clock stretching и обнаруживать потерю арбитража.

Код написан. Он компилируется. Но **работает ли он правильно**?

На этом этапе у нас ещё нет обёрток, регистровых интерфейсов, прерываний — ничего, кроме голого ядра. И это прекрасно, потому что тестировать нужно именно **сейчас**, пока модуль изолирован и прост. Если мы найдём ошибку сейчас — исправить её элементарно. Если ошибка всплывёт позже, в составе большой системы — придётся разбираться, кто из десятка компонентов виноват.

> **Принцип: тестируй снизу вверх.** Самый низкий модуль в иерархии проекта тестируется первым. `i2c_master_core` — это фундамент. Все остальные модули будут полагаться на то, что он работает корректно. Если фундамент гнилой — всё, что над ним, обречено.

### Что такое тестбенч

Тестбенч (testbench) — это **модуль-обёртка**, который существует только для целей моделирования. Он не синтезируется в реальное железо. Его задача — подать на входы тестируемого модуля (DUT — Design Under Test) нужные сигналы, дождаться ответов на выходах, и проверить, совпадают ли они с ожиданием.

Наш тестбенч (`tb/i2c_core_tb.sv`) состоит из следующих компонентов:

```
    ┌──────────────────────────────────────────────────────────────────┐
    │                       i2c_core_tb                                │
    │                                                                  │
    │  ┌──────────────┐        ┌─────────────────────────────┐         │
    │  │  Генератор   │ clk    │                             │         │
    │  │ клока и ena  │───────►│                             │         │
    │  └──────────────┘        │     i2c_master_core         │         │
    │                          │         (DUT)               │         │
    │  ┌──────────────┐ cmd_i  │                             │         │
    │  │ Управляющая  │───────►│                     scl_oen │         │
    │  │   логика     │ din_i  │                     sda_oen │         │
    │  │(initial-блок)│───────►│                        │  │ │         │
    │  │              │◄───────┤ ready_o, dout_o,       │  │ │         │
    │  │              │        │ rx_ack_o, busy_o       │  │ │         │
    │  └──────────────┘        └───────────────────────│──│─┘         │
    │                                                  │  │           │
    │            ┌──── I2C шина (wire sda, scl) ───────┤  │           │
    │            │                                     │  │           │
    │            │    ┌──────────┐  ┌──────────┐       │  │           │
    │            │    │ pullup R │  │ pullup R │       │  │           │
    │            │    └────┬─────┘  └────┬─────┘       │  │           │
    │            │         │SCL          │SDA           │  │           │
    │            │         │             │              │  │           │
    │  ┌─────────┴─────────┴─────────────┴──────────┐  │  │           │
    │  │                                            │  │  │           │
    │  │  ┌──────────────────┐ ┌──────────────────┐ │  │  │           │
    │  │  │ i2c_slave_model  │ │ i2c_slave_model  │ │  │  │           │
    │  │  │  addr = 0x50     │ │  addr = 0x51     │ │  │  │           │
    │  │  │  (обычный)       │ │  (+ stretching)  │ │  │  │           │
    │  │  └──────────────────┘ └──────────────────┘ │  │  │           │
    │  │                                            │  │  │           │
    │  │  ┌──────────────────┐   ┌───────────────┐  │  │  │           │
    │  │  │  SCL-hold логика │   │ ext_sda_drive │  │  │  │           │
    │  │  │  (stretching)    │   │ (арбитраж)    │  │  │  │           │
    │  │  └──────────────────┘   └───────────────┘  │  │  │           │
    │  └────────────────────────────────────────────┘  │  │           │
    └──────────────────────────────────────────────────────────────────┘
```

1. **Генератор клока и ena** — создаёт тактовый сигнал `clk` и разрешающий импульс `ena_i`
2. **Управляющая логика** — `initial`-блок с 10 тестовыми сценариями
3. **DUT** — сам `i2c_master_core`
4. **Два slave** — обычный на адресе 0x50 и slave с clock stretching на адресе 0x51
5. **SCL-hold логика** — удерживает SCL в LOW для имитации clock stretching
6. **ext_sda_drive** — внешний драйвер SDA для имитации потери арбитража

---

## 2. Интерфейс i2c_master_core — ваш «пульт управления»

Прежде чем писать тесты, нужно понять, чем мы управляем. Вот полный набор портов ядра:

```
                         ┌─────────────────────────────────┐
                         │        i2c_master_core          │
                         │                                 │
  Тактирование:          │                                 │
    clk_i  ─────────────►│  Системный клок                 │
    rstn_i ─────────────►│  Сброс (активный LOW)           │
    ena_i  ─────────────►│  Разрешающий импульс             │
                         │  (1 тик за ¼ периода SCL)       │
                         │                                 │
  Команды (вход):        │                                 │
    cmd_valid_i ────────►│  «Есть команда»                 │      I2C шина:
    cmd_i[2:0]  ────────►│  Код команды                    │
    din_i[7:0]  ────────►│  Данные для передачи             │        SCL ◄──► scl_i
                         │                                 │              scl_oen_o
  Результат (выход):     │                                 │
    ready_o    ◄─────────┤  «Готов к следующей команде»     │        SDA ◄──► sda_i
    dout_o[7:0]◄─────────┤  Принятые данные                │              sda_oen_o
    rx_ack_o   ◄─────────┤  ACK/NACK от slave              │
                         │                                 │
  Статус:                │                                 │
    busy_o     ◄─────────┤  Шина занята                    │
    arb_lost_o ◄─────────┤  Арбитраж потерян (sticky)      │
    arb_lost_clear_i ───►│  Сброс флага arb_lost           │
                         │                                 │
                         └─────────────────────────────────┘
```

### 2.1. Пять команд

| cmd_i | Код | Что делает |
|-------|-----|-----------|
| `CMD_NOP` | 3'd0 | Ничего (игнорируется) |
| `CMD_START` | 3'd1 | Генерирует START-условие на шине |
| `CMD_WRITE` | 3'd2 | Передаёт 8 бит из `din_i`, принимает ACK/NACK от slave |
| `CMD_READ` | 3'd3 | Принимает 8 бит от slave, отправляет ACK или NACK (зависит от `din_i[0]`) |
| `CMD_STOP` | 3'd4 | Генерирует STOP-условие |
| `CMD_RESTART` | 3'd5 | Генерирует повторный START (без промежуточного STOP) |

### 2.2. Сигнал ena_i — «метроном» ядра

Ядро продвигает свой автомат только на тактах, когда `ena_i = 1`. На всех остальных тактах ядро «стоит».

Каждый бит на I2C шине занимает 4 такта `ena_i` (4 фазы). Один байт — 9 бит (8 данных + 1 ACK/NACK) = 36 тактов `ena_i`. Реальный период SCL = 4 × период `ena_i`.

В конечном устройстве `ena_i` будет генерироваться прескалером. Но прескалер мы ещё не написали, поэтому генерируем `ena` простым счётчиком прямо в тестбенче:

```verilog
localparam ENA_DIV = 4;   // ena каждые 4 такта clk

reg [7:0] ena_cnt;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ena_cnt <= 0;
        ena     <= 0;
    end else begin
        if (ena_cnt == ENA_DIV - 1) begin
            ena_cnt <= 0;
            ena     <= 1;
        end else begin
            ena_cnt <= ena_cnt + 1;
            ena     <= 0;
        end
    end
end
```

При `CLK_PERIOD = 10` нс (100 МГц) и `ENA_DIV = 4` получаем `ena` каждые 40 нс. Период SCL = 4 × 40 нс = 160 нс. Для моделирования это удобно — тесты завершаются быстро.

### 2.3. Протокол рукопожатия (handshake)

```
       Тестбенч                         Ядро
       ────────                         ────
  1. Ждём ready_o == 1           ready_o = 1 (жду команду)
  2. Выставляем cmd_i, din_i
  3. Поднимаем cmd_valid_i = 1
                              ──────►
                                    4. Ядро видит cmd_valid_i=1
                                       Сбрасывает ready_o = 0
                                       Начинает выполнение
                              ◄──────
  5. Видим ready_o = 0
     (можно снять cmd_valid_i)
                                    6. Ядро работает (36 ena-тиков
                                       для 9 бит × 4 фазы)
                                    7. Заканчивает:
                                       ready_o = 1
                                       dout_o = данные
                                       rx_ack_o = ACK/NACK
                              ◄──────
  8. Видим ready_o == 1
     Читаем dout_o, rx_ack_o
     Переходим к следующей команде
```

---

## 3. Каркас тестбенча

### 3.1. Параметры

```verilog
localparam CLK_PERIOD = 10;                   // 100 МГц
localparam ENA_DIV    = 4;                    // ena каждые 4 такта
localparam [6:0] SLAVE_ADDR     = 7'h50;     // Обычный slave
localparam [6:0] SLAVE_ADDR_STR = 7'h51;     // Slave с clock stretching
localparam       STRETCH_CYCLES = 80;         // Сколько тактов clk держать SCL
localparam       TIMEOUT_LIMIT  = 200_000;    // Защита от зависания
```

- **Два адреса slave:** обычный `0x50` для тестов 1–5, 7–10 и slave с clock stretching `0x51` для теста 6.
- **TIMEOUT_LIMIT:** все ожидания в task-ах защищены таймаутом. Если ядро «зависнет», тест не застрянет навечно — через 200 000 тактов выдаст FAIL.
- **STRETCH_CYCLES = 80:** slave удерживает SCL на 80 тактов clk (= 800 нс при 100 МГц).

### 3.2. I2C шина и open-drain

```verilog
wire sda, scl;
pullup (sda);
pullup (scl);

// Open-drain выход мастера
assign scl = scl_oen ? 1'bz : 1'b0;
assign sda = sda_oen ? 1'bz : 1'b0;

// Внешний интерферер для теста арбитража
reg ext_sda_drive;
assign sda = (ext_sda_drive) ? 1'b0 : 1'bz;

wire scl_i = scl;
wire sda_i = sda;
```

На шине `sda` работают **три** драйвера:
1. Мастер (DUT): `scl_oen`/`sda_oen`
2. Slave-модели: внутренний `sda_out_en`
3. Интерферер: `ext_sda_drive`

Все три — open-drain (тянут к 0 или отпускают). Результирующее значение на шине — wired-AND: если хотя бы один тянет к 0, шина = 0.

### 3.3. Два slave-устройства

```verilog
// Обычный slave (addr 0x50)
i2c_slave_model #(.I2C_ADDR(SLAVE_ADDR)) slave (
    .sda_io (sda),
    .scl_io (scl)
);

// Slave с clock stretching (addr 0x51)
i2c_slave_model #(.I2C_ADDR(SLAVE_ADDR_STR)) slave_str (
    .sda_io (sda),
    .scl_io (scl)
);
```

Обе модели сидят на одной шине, но отвечают на разные адреса. Это стандартная практика для I2C — на одной шине может быть много устройств.

### 3.4. Логика clock stretching

Clock stretching реализован прямо в тестбенче, а не внутри slave-модели:

```verilog
reg scl_hold;
assign scl = scl_hold ? 1'b0 : 1'bz;

integer stretch_cnt;

always @(negedge scl) begin
    if (slave_str.state == 4'd2 ||   // S_ADDR_ACK
        slave_str.state == 4'd4 ||   // S_REG_ACK
        slave_str.state == 4'd6) begin // S_WR_ACK
        scl_hold    <= 1;
        stretch_cnt <= STRETCH_CYCLES;
    end
end

always @(posedge clk) begin
    if (scl_hold && stretch_cnt > 0)
        stretch_cnt <= stretch_cnt - 1;
    else if (scl_hold && stretch_cnt == 0)
        scl_hold <= 0;
end
```

Логика: когда slave `slave_str` переходит в состояние ACK (после адреса, регистра или данных), мы «захватываем» SCL — тянем к 0 на `STRETCH_CYCLES` тактов. Мастер в это время пытается отпустить SCL, но не может (wired-AND). Через 80 тактов мы отпускаем SCL, мастер видит `scl_i = 1` и продолжает.

Мы подглядываем во внутренний `state` slave-модели через иерархический путь `slave_str.state`. Это допустимо в тестбенче — мы не синтезируем этот код.

### 3.5. Вспомогательные task-и

```verilog
integer pass_cnt, fail_cnt;

task test_pass(input [80*8-1:0] msg);
    begin
        $display("  PASS: %0s", msg);
        pass_cnt = pass_cnt + 1;
    end
endtask

task test_fail(input [80*8-1:0] msg);
    begin
        $display("  FAIL: %0s", msg);
        fail_cnt = fail_cnt + 1;
    end
endtask
```

Счётчики `pass_cnt` и `fail_cnt` инкрементируются при каждой проверке. В конце теста выводится итог: `PASS=N FAIL=M`.

Базовый task отправки команды — с защитой от зависания:

```verilog
task send_cmd(input [2:0] c, input [7:0] d);
    integer wcnt;
    begin
        @(posedge clk);
        wcnt = 0;
        while (!ready) begin                      // 1. Ждём готовности
            @(posedge clk);
            wcnt = wcnt + 1;
            if (wcnt > TIMEOUT_LIMIT) begin
                test_fail("TIMEOUT waiting for ready before cmd");
                disable send_cmd;
            end
        end
        cmd       <= c;                            // 2. Выставляем команду
        din       <= d;
        cmd_valid <= 1;
        @(posedge clk);
        wcnt = 0;
        while (ready) begin                        // 3. Ждём, пока ядро примет
            @(posedge clk);
            wcnt = wcnt + 1;
            if (wcnt > TIMEOUT_LIMIT) begin
                test_fail("TIMEOUT: ready never fell");
                cmd_valid <= 0;
                disable send_cmd;
            end
        end
        cmd_valid <= 0;                            // 4. Снимаем запрос
        cmd       <= CMD_NOP;
        wcnt = 0;
        while (!ready) begin                       // 5. Ждём завершения
            @(posedge clk);
            wcnt = wcnt + 1;
            if (wcnt > TIMEOUT_LIMIT) begin
                test_fail("TIMEOUT waiting for ready after cmd");
                disable send_cmd;
            end
        end
    end
endtask
```

Каждое ожидание защищено: если `ready` не изменится за `TIMEOUT_LIMIT` тактов, task выходит через `disable` с сообщением FAIL. Без этого баг в ядре мог бы превратить тест в бесконечный цикл.

Обёртки:

```verilog
task do_start;   begin send_cmd(CMD_START,   8'd0); end endtask
task do_stop;    begin send_cmd(CMD_STOP,    8'd0); end endtask
task do_restart; begin send_cmd(CMD_RESTART, 8'd0); end endtask

task do_write(input [7:0] data, output ack);
    begin  send_cmd(CMD_WRITE, data);  ack = rx_ack;  end
endtask

task do_read(input nack_bit, output [7:0] data);
    begin  send_cmd(CMD_READ, {7'd0, nack_bit});  data = dout;  end
endtask
```

---

## 4. Тест 1: Single WRITE + ACK

### Цель

Самый первый и самый простой тест. Убедиться, что ядро может передать один байт и услышать ACK от slave.

### Что происходит внутри ядра — по тактам

Когда мы подаём `CMD_WRITE` с `din_i = 0xA0` (адресный байт: slave 0x50 + бит записи):

```
Такт 0 (ena): Ядро защёлкивает команду
    tx_shift_r <= {0xA0, 1'b0} = 9'b_1_0100_000_0
    bit_cnt_r  <= 0
    state_r    <= ST_DATA
    ready_o    <= 0            ← «Я занят»
```

Далее 9 бит-слотов × 4 фазы = 36 тактов `ena`:

```
Бит 0 (MSB = 1):
  Фаза 0: SCL=0, SDA=tx_shift_r[8]=1  (отпустил)
  Фаза 1: SCL=1, семплирование sda_i
  Фаза 2: SCL=1, удержание
  Фаза 3: SCL=0, сдвиг регистра, bit_cnt_r <= 1
...
Бит 8 (ACK-слот):
  Фаза 0: SCL=0, sda_input_mode=1 → sda_oen_o=1 (отпускаем SDA для slave)
  Фаза 1: SCL=1, семплируем sda_i → rx_shift_r[0]
  Фаза 3: bit_cnt_r == 8 → rx_ack_o <= rx_shift_r[0], ready_o <= 1
```

### Код теста

```verilog
$display("\n=== TEST 1: Single WRITE + ACK ===");
begin : test1
    reg ack;
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);       // 0x50 + W = 0xA0

    if (ack == 1'b0)
        test_pass("Slave ACK received (rx_ack_o = 0)");
    else
        test_fail("Expected ACK, got NACK");

    do_stop;
end
```

### На что смотреть в осциллограмме

| Сигнал | Что показывает |
|--------|----------------|
| `dut.state_r` | 0=IDLE, 2=DATA |
| `dut.phase_r` | 0→1→2→3 в каждом бите |
| `dut.bit_cnt_r` | 0…8 |
| `dut.tx_shift_r` | Сдвиговый регистр, убывает побитно |
| `sda`, `scl` | Сигналы на шине |
| `dut.rx_ack_o` | 0=ACK, 1=NACK |
| `dut.ready_o` | 0 во время работы, 1 по завершении |

### Что может пойти не так

| Симптом | Возможная причина |
|---------|-------------------|
| `rx_ack_o = 1` (NACK) | `sda_input_mode` не активируется на 9-м бите → ядро само держит SDA=1 |
| Тайм-аут (ready не поднимается) | `bit_cnt_r` не доходит до 8 |
| Данные на шине неправильные | `tx_shift_r` сдвигается не в ту сторону |

---

## 5. Тест 2: Single READ + NACK

### Цель

Убедиться, что ядро корректно принимает 8 бит данных от slave и отправляет NACK.

### Ключевая механика

При WRITE ядро **передаёт** (управляет SDA 8 бит, слушает 1 бит ACK).
При READ ядро **принимает** (слушает SDA 8 бит, управляет 1 бит ACK/NACK).

Переключение определяется проводом `sda_input_mode`:

```verilog
wire sda_input_mode = (state_r == ST_DATA) && (
    (cmd_r == CMD_READ  && bit_cnt_r < 4'd8) ||
    (cmd_r == CMD_WRITE && bit_cnt_r == 4'd8)
);
```

`tx_shift_r` для READ инициализируется как `{8'hFF, din_i[0]}` — все единицы (отпускаем SDA) + бит ACK/NACK от мастера. `din_i[0] = 1` → NACK, `din_i[0] = 0` → ACK.

### Код теста

Сначала записываем 0xA5 в ячейку 0x10, потом читаем обратно:

```verilog
$display("\n=== TEST 2: Single READ + NACK ===");
begin : test2
    reg ack;
    reg [7:0] rdata;

    // Записываем 0xA5 в ячейку 0x10
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);
    do_write(8'h10, ack);
    do_write(8'hA5, ack);
    do_stop;

    repeat (50) @(posedge clk);

    // Читаем обратно через RESTART
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);
    do_write(8'h10, ack);
    do_restart;
    do_write({SLAVE_ADDR, 1'b1}, ack);
    do_read(1'b1, rdata);                     // 1'b1 = NACK
    do_stop;

    if (rdata === 8'hA5)
        test_pass("Read 0xA5 matches written value");
    else
        test_fail("Read mismatch");
end
```

### Неочевидная деталь: sda_oen = tx_shift_r[8]

`tx_shift_r[8]` одновременно означает и «значение бита на SDA» и «output enable». Это работает благодаря инверсной логике open-drain: «хочу передать 1» = «не тяну линию» = `oen = 1`. Для NACK: `din_i[0] = 1` → `oen = 1` → pull-up → SDA = 1 → NACK.

---

## 6. Тест 3: Полная транзакция START + WRITE addr + WRITE data + STOP

### Цель

Проверить полный цикл записи, отслеживая переходы FSM и флаг `busy_o`.

### Что мы проверяем

- `busy_o` устанавливается после START и сбрасывается после STOP
- Между командами в IDLE ядро **не отпускает линии** при `busy_o = 1`
- Оба байта (адрес + данные) получают ACK от slave

### Критичный момент: IDLE между командами

```verilog
ST_IDLE: begin
    if (cmd_valid_i && !arb_lost_o) begin
        ...
    end else if (!busy_o) begin
        scl_oen_o <= 1'b1;    // Отпускаем только если шина свободна
        sda_oen_o <= 1'b1;
    end
    // busy_o=1 → линии не трогаем!
end
```

Если бы ядро отпустило SDA при SCL=HIGH внутри транзакции, slave увидел бы ложный STOP.

### Код теста

```verilog
$display("\n=== TEST 3: Full transaction ===");
begin : test3
    reg ack1, ack2;

    do_start;

    if (busy !== 1'b1)
        test_fail("busy_o should be 1 after START");

    do_write({SLAVE_ADDR, 1'b0}, ack1);
    if (ack1 !== 1'b0)
        test_fail("Expected ACK on address byte");

    do_write(8'h42, ack2);
    if (ack2 !== 1'b0)
        test_fail("Expected ACK on data byte");

    do_stop;

    repeat (10) @(posedge clk);
    if (busy !== 1'b0)
        test_fail("busy_o should be 0 after STOP");
    else
        test_pass("Full transaction OK, busy cleared");
end
```

---

## 7. Тест 4: Repeated START (RESTART)

### Цель

Проверить генерацию повторного START без освобождения шины.

### Чем RESTART отличается от START

```
RESTART:                              START:
  Фаза 0: SDA=1, SCL=0               Фаза 0: SDA=1, SCL=1 (ждём scl_i)
  Фаза 1: SDA=1, SCL=1 (ждём)        Фаза 1: SDA=1, SCL=1 (удержание)
  Фаза 2: SDA=0, SCL=1 (START!)      Фаза 2: SDA=0, SCL=1 (START!)
  Фаза 3: SDA=0, SCL=0               Фаза 3: SDA=0, SCL=0
```

START начинает с обоих линий HIGH (шина свободна). RESTART начинает с SCL=LOW (мы только что передавали данные) — сначала поднимает SDA, потом отпускает SCL.

### Код теста

```verilog
$display("\n=== TEST 4: Repeated START (RESTART) ===");
begin : test4
    reg ack;
    reg [7:0] rdata;

    // Записываем 0xBE в ячейку 0x20
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);
    do_write(8'h20, ack);
    do_write(8'hBE, ack);
    do_stop;

    repeat (50) @(posedge clk);

    // Читаем обратно через RESTART
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);
    do_write(8'h20, ack);
    do_restart;

    if (busy !== 1'b1)
        test_fail("busy_o dropped during RESTART");

    do_write({SLAVE_ADDR, 1'b1}, ack);
    do_read(1'b1, rdata);
    do_stop;

    if (rdata === 8'hBE)
        test_pass("RESTART read-back OK");
    else
        test_fail("RESTART read-back mismatch");
end
```

### Ключевая проверка

В осциллограмме `busy_o` должен быть непрерывной «1» от первого START до финального STOP. Если `busy_o` мигнёт в 0 — значит, ядро сгенерировало ложный STOP.

---

## 8. Тест 5: NACK от slave + восстановление

### Цель

Убедиться, что ядро фиксирует NACK, не зависает, и нормально работает после этого.

### Код теста

```verilog
$display("\n=== TEST 5: NACK from slave ===");
begin : test5
    reg ack;

    do_start;
    do_write({7'h3F, 1'b0}, ack);         // Адрес 0x3F — нет такого slave

    if (ack === 1'b1)
        test_pass("Got NACK for nonexistent address 0x3F");
    else
        test_fail("Expected NACK, got ACK for 0x3F");

    do_stop;

    repeat (10) @(posedge clk);
    if (busy !== 1'b0)
        test_fail("busy_o not cleared after NACK + STOP");

    // Восстановление: правильный адрес после NACK
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);
    if (ack === 1'b0)
        test_pass("Normal ACK after NACK recovery");
    else
        test_fail("Controller stuck after NACK");
    do_stop;
end
```

Тест проверяет **две вещи**: NACK на неправильном адресе и корректную работу после NACK + STOP. Это важно — ядро не должно «застревать» после ошибочной адресации.

---

## 9. Тест 6: Clock stretching

### Цель

Убедиться, что ядро корректно ожидает, когда slave удерживает SCL в LOW.

### Как это работает в тестбенче

Вместо обычного slave (0x50) тест использует slave на адресе **0x51** (`SLAVE_ADDR_STR`). После каждого ACK от slave_str, SCL-hold логика тянет SCL к 0 на 80 тактов. Ядро отпускает SCL (`scl_oen = 1`), но `scl_i = 0` (slave держит). Ядро ждёт в фазе 1 пока `scl_i` не станет 1.

```
                    Slave держит SCL         Slave отпускает
                    ↓                         ↓
scl_oen_o: ────────╱ HIGH (ядро отпустило) ──╱ HIGH
scl (шина): ──── LOW!!! (slave тянет)  ─────╱ HIGH (pull-up)
                    │←── 80 тактов clk ──→│
phase_r:     ... 1  1  1  1  1  1  1  1  2  3  0  1  2 ...
```

### Код теста

```verilog
$display("\n=== TEST 6: Clock stretching ===");
begin : test6
    reg ack;
    reg [7:0] rdata;

    do_start;
    do_write({SLAVE_ADDR_STR, 1'b0}, ack);    // Slave 0x51
    if (ack !== 1'b0) begin
        test_fail("Stretching slave NACK on address");
    end else begin
        do_write(8'h30, ack);
        do_write(8'hCD, ack);
        do_stop;

        repeat (50) @(posedge clk);

        // Читаем обратно
        do_start;
        do_write({SLAVE_ADDR_STR, 1'b0}, ack);
        do_write(8'h30, ack);
        do_restart;
        do_write({SLAVE_ADDR_STR, 1'b1}, ack);
        do_read(1'b1, rdata);
        do_stop;

        if (rdata === 8'hCD)
            test_pass("Clock stretching handled OK");
        else
            test_fail("Data corrupted after stretching");
    end
end
```

Обратите внимание на `if/else` — если stretching-slave не ответит ACK на свой адрес, тест не будет пытаться продолжать (записывать/читать), а сразу зафиксирует FAIL.

---

## 10. Тест 7: Arbitration lost

### Цель

Убедиться, что ядро обнаруживает конфликт на шине и немедленно отпускает её.

### Как имитируем потерю арбитража

Используем `ext_sda_drive` — когда он = 1, SDA принудительно тянется к 0. Если ядро в этот момент отпустило SDA (ожидает 1), оно увидит `sda_i = 0` → арбитраж потерян.

### Код теста

Тест 7 — самый сложный, потому что нужно «вмешаться» в нужный момент:

```verilog
$display("\n=== TEST 7: Arbitration lost ===");
begin : test7
    do_start;

    // Ручная подача WRITE (не через do_write), чтобы поймать нужный момент
    cmd       <= CMD_WRITE;
    din       <= {SLAVE_ADDR, 1'b0};       // 0xA0, MSB=1 → ядро отпустит SDA
    cmd_valid <= 1;
    @(posedge clk);
    // Ждём пока ядро примет команду (ready упадёт)
    begin : test7_wait_accept
        integer wc;
        wc = 0;
        while (ready) begin
            @(posedge clk);
            wc = wc + 1;
            if (wc > TIMEOUT_LIMIT) begin
                test_fail("TIMEOUT waiting for core to accept WRITE");
                disable test7;
            end
        end
    end
    cmd_valid <= 0;

    // Ждём, пока ядро войдёт в ST_DATA, phase 0
    begin : test7_wait_data
        integer wc;
        wc = 0;
        while (!(dut.state_r == 3'd2 && dut.phase_r == 2'd0)) begin
            @(posedge clk);
            wc = wc + 1;
            if (wc > TIMEOUT_LIMIT) begin
                test_fail("TIMEOUT waiting for DATA phase 0");
                disable test7;
            end
        end
    end
    @(posedge clk);

    // Врезаемся: тянем SDA к 0
    ext_sda_drive <= 1;

    // Ждём arb_lost
    begin : test7_wait_arb
        integer wc;
        wc = 0;
        while (arb_lost !== 1'b1) begin
            @(posedge clk);
            wc = wc + 1;
            if (wc > TIMEOUT_LIMIT) begin
                test_fail("TIMEOUT waiting for arb_lost");
                ext_sda_drive <= 0;
                disable test7;
            end
        end
    end
    ext_sda_drive <= 0;

    // ---- Проверки ----

    // 1. Арбитраж обнаружен
    if (arb_lost === 1'b1)
        test_pass("Arbitration lost detected");
    else
        test_fail("Arbitration lost NOT detected");

    // 2. Шина отпущена
    if (dut.scl_oen_o === 1'b1 && dut.sda_oen_o === 1'b1)
        test_pass("Bus released after arb_lost");
    else
        test_fail("Bus NOT released after arb_lost");

    // 3. Команды игнорируются при arb_lost=1
    cmd_valid <= 1;
    cmd       <= CMD_START;
    repeat (20) @(posedge clk);
    if (ready === 1'b1)
        test_pass("Core ignores commands while arb_lost=1");
    else
        test_fail("Core accepted command despite arb_lost=1");
    cmd_valid <= 0;
    cmd       <= CMD_NOP;

    // 4. Сброс флага
    arb_lost_clear <= 1;
    @(posedge clk);
    arb_lost_clear <= 0;
    repeat (5) @(posedge clk);

    if (arb_lost === 1'b0)
        test_pass("arb_lost cleared");
    else
        test_fail("arb_lost NOT cleared");

    do_stop;
end
```

Тест выдаёт **4 проверки**: обнаружение, освобождение шины, блокировка команд, сброс флага.

### Почему используются именованные блоки с disable

В `send_cmd` при таймауте используется `disable send_cmd`. Но в тесте 7 мы управляем командами вручную (не через `send_cmd`), поэтому используем `disable test7` — это выход из всего блока `begin : test7 ... end`. Каждый `while`-цикл обёрнут в именованный блок с собственным счётчиком `wc`.

---

## 11. Тест 8: Reset во время транзакции

### Цель

Убедиться, что аппаратный сброс возвращает ядро в начальное состояние из середины передачи, и после сброса ядро работает нормально.

### Код теста

```verilog
$display("\n=== TEST 8: Reset during transaction ===");
begin : test8
    reg ack;
    reg [7:0] rdata;

    do_start;

    // Начинаем WRITE вручную
    cmd       <= CMD_WRITE;
    din       <= {SLAVE_ADDR, 1'b0};
    cmd_valid <= 1;
    @(posedge clk);
    begin : test8_wait
        integer wc;
        wc = 0;
        while (ready) begin
            @(posedge clk);
            wc = wc + 1;
            if (wc > TIMEOUT_LIMIT) begin
                test_fail("TIMEOUT in reset test setup");
                disable test8;
            end
        end
    end
    cmd_valid <= 0;

    // Ждём 4 фазы 3 (= 4 бита переданы — середина байта)
    repeat (4) begin : test8_bits
        integer wc;
        wc = 0;
        while (dut.phase_r != 2'd3) begin
            @(posedge clk);
            wc = wc + 1;
            if (wc > TIMEOUT_LIMIT) begin
                test_fail("TIMEOUT waiting for phase 3");
                disable test8;
            end
        end
        @(posedge clk);
    end

    // Сброс!
    rstn <= 0;
    repeat (10) @(posedge clk);
    rstn <= 1;
    repeat (20) @(posedge clk);

    // Проверяем состояние после сброса
    if (dut.state_r !== 3'd0)   test_fail("state_r not IDLE after reset");
    if (dut.scl_oen_o !== 1'b1 || dut.sda_oen_o !== 1'b1)
                                test_fail("Bus not released after reset");
    if (ready !== 1'b1)         test_fail("ready_o not 1 after reset");
    if (busy !== 1'b0)          test_fail("busy_o not 0 after reset");
    if (arb_lost !== 1'b0)      test_fail("arb_lost_o not 0 after reset");

    // Проверяем, что ядро РАБОТАЕТ после сброса
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);
    if (ack !== 1'b0)
        test_fail("NACK after reset — controller broken");

    do_write(8'h70, ack);
    do_write(8'hEE, ack);
    do_stop;

    repeat (50) @(posedge clk);

    // Читаем обратно
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);
    do_write(8'h70, ack);
    do_restart;
    do_write({SLAVE_ADDR, 1'b1}, ack);
    do_read(1'b1, rdata);
    do_stop;

    if (rdata === 8'hEE)
        test_pass("Post-reset write/read OK");
    else
        test_fail("Post-reset data mismatch");
end
```

### Тонкость: sda_d_r сбрасывается в 1

Регистр `sda_d_r` (задержанная копия `sda_i`) сбрасывается в **1**, а не в 0. Это исключает ложные фронты на SDA после снятия сброса: `sda_rising = sda_i & ~sda_d_r`. Если бы `sda_d_r = 0` и `sda_i = 1` (pull-up), то `sda_rising = 1` при `scl_i = 1` → ложный STOP → некорректный `busy_o`.

---

## 12. Тест 9: CMD_NOP

### Цель

Убедиться, что NOP не вызывает никаких побочных эффектов.

### Код теста

```verilog
$display("\n=== TEST 9: CMD_NOP ===");
begin : test9
    @(posedge clk);
    cmd       <= CMD_NOP;
    din       <= 8'hFF;
    cmd_valid <= 1;
    repeat (20) @(posedge clk);
    cmd_valid <= 0;
    cmd       <= CMD_NOP;

    if (dut.state_r === 3'd0 && ready === 1'b1)
        test_pass("NOP: state stayed IDLE, ready=1");
    else
        test_fail("NOP: unexpected state change");
end
```

NOP не проходит через `send_cmd`, потому что `send_cmd` ждёт падения `ready`. Но NOP — это «ничего не делать», ядро его игнорирует, `ready` никогда не упадёт. Поэтому тут мы вручную держим `cmd_valid = 1` с `CMD_NOP` 20 тактов и проверяем, что ничего не изменилось.

---

## 13. Тест 10: Последовательное чтение (4 байта)

### Цель

Проверить, что ядро корректно выполняет серию READ с ACK, завершая NACK-ом.

### Код теста

```verilog
$display("\n=== TEST 10: Sequential read (4 bytes) ===");
begin : test10
    reg ack;
    reg [7:0] r0, r1, r2, r3;
    integer seq_ok;

    // Slave-модель инициализирует mem[i] = i
    do_start;
    do_write({SLAVE_ADDR, 1'b0}, ack);
    do_write(8'h00, ack);              // Адрес ячейки 0x00
    do_restart;
    do_write({SLAVE_ADDR, 1'b1}, ack); // Переключаемся на чтение

    do_read(1'b0, r0);                // ACK → ещё
    do_read(1'b0, r1);                // ACK → ещё
    do_read(1'b0, r2);                // ACK → ещё
    do_read(1'b1, r3);                // NACK → всё

    do_stop;

    seq_ok = (r0 === 8'h00) && (r1 === 8'h01) &&
             (r2 === 8'h02) && (r3 === 8'h03);

    if (seq_ok)
        test_pass("Sequential read 00,01,02,03 OK");
    else begin
        $display("    got: %02h %02h %02h %02h", r0, r1, r2, r3);
        test_fail("Sequential read mismatch");
    end
end
```

Slave-модель при инициализации заполняет память `mem[i] = i`. Поэтому чтение с адреса 0x00 должно вернуть 0x00, 0x01, 0x02, 0x03. При ошибке тест выводит реально полученные значения — удобно для диагностики.

---

## 14. Watchdog и итоговый отчёт

### Watchdog

```verilog
initial begin
    #(TIMEOUT_LIMIT * CLK_PERIOD * 20);
    $display("WATCHDOG: simulation timeout");
    $finish;
end
```

Если вся симуляция займёт больше `200_000 × 10 × 20 = 40 000 000 000` пс = 40 мс модельного времени, watchdog принудительно завершит её. Это защита от бесконечных циклов.

### Итоговый отчёт

```verilog
$display("\n========================================");
$display("  TEST SUMMARY:  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
if (fail_cnt == 0)
    $display("  All tests PASSED");
else
    $display("  *** FAILURES DETECTED ***");
$display("========================================\n");
```

---

## 15. Сводная таблица

| # | Тест | Проверки | Ключевые сигналы |
|---|------|----------|------------------|
| 1 | WRITE + ACK | `rx_ack_o = 0` | `state_r`, `bit_cnt_r`, `sda_oen_o`, `rx_ack_o` |
| 2 | READ + NACK | `dout_o == 0xA5` | `dout_o`, `sda_oen_o` в ACK-слоте |
| 3 | Полная транзакция | `busy_o`: 1 после START, 0 после STOP | `busy_o`, `state_r` |
| 4 | RESTART | `busy_o` не мигает, данные корректны | `busy_o` (непрерывная 1) |
| 5 | NACK + восстановление | NACK на 0x3F, ACK на 0x50 после | `rx_ack_o`, `ready_o` |
| 6 | Clock stretching | Данные корректны при stretching slave (0x51) | `phase_r` «залипает» на 1 |
| 7 | Arbitration lost | 4 проверки: обнаружение, отпускание, блокировка, сброс | `arb_lost_o`, `scl_oen_o`, `sda_oen_o` |
| 8 | Reset | Все регистры в начальные + write/read после | `state_r`, `ready_o`, `busy_o` |
| 9 | CMD_NOP | state остаётся IDLE, ready = 1 | `state_r`, `ready_o` |
| 10 | Sequential read | 4 байта: 0x00, 0x01, 0x02, 0x03 | `dout_o` четыре раза |

Всего: **14 проверок** (PASS/FAIL) в 10 тестах.

---

## 16. Как запустить

### 16.1. Компиляция и запуск

```bash
make sim-core
```

Это эквивалентно:

```bash
mkdir -p sim
iverilog -g2012 -Wall -o sim/i2c_core_tb.vvp \
    rtl/i2c_master_core.v \
    tb/i2c_slave_model.sv \
    tb/i2c_core_tb.sv
cd sim && vvp ../sim/i2c_core_tb.vvp
```

### 16.2. Lint-проверка ядра

```bash
make lint-core
```

### 16.3. Просмотр осциллограмм

```bash
gtkwave sim/i2c_core_tb.vcd
```

### 16.4. Рекомендуемый набор сигналов для GTKWave

| Группа | Сигналы |
|--------|---------|
| Шина | `sda`, `scl` |
| Управление | `cmd_valid`, `cmd`, `din`, `ready`, `ena` |
| Результат | `dout`, `rx_ack` |
| Статус | `busy`, `arb_lost` |
| FSM (DUT) | `dut.state_r`, `dut.phase_r`, `dut.bit_cnt_r` |
| Сдвиговые | `dut.tx_shift_r`, `dut.rx_shift_r` |
| Open-drain | `dut.scl_oen_o`, `dut.sda_oen_o` |
| Slave | `slave.state`, `slave.sr`, `slave.bcnt`, `slave.sda_out_en` |
| Stretching | `scl_hold`, `stretch_cnt`, `slave_str.state` |
| Арбитраж | `ext_sda_drive`, `arb_lost` |

### 16.5. Ожидаемый вывод

```
=== TEST 1: Single WRITE + ACK ===
  PASS: Slave ACK received (rx_ack_o = 0)

=== TEST 2: Single READ + NACK ===
  PASS: Read 0xA5 matches written value

=== TEST 3: Full transaction ===
  PASS: Full transaction OK, busy cleared

=== TEST 4: Repeated START (RESTART) ===
  PASS: RESTART read-back OK

=== TEST 5: NACK from slave ===
  PASS: Got NACK for nonexistent address 0x3F
  PASS: Normal ACK after NACK recovery

=== TEST 6: Clock stretching ===
  PASS: Clock stretching handled OK

=== TEST 7: Arbitration lost ===
  PASS: Arbitration lost detected
  PASS: Bus released after arb_lost
  PASS: Core ignores commands while arb_lost=1
  PASS: arb_lost cleared

=== TEST 8: Reset during transaction ===
  PASS: Post-reset write/read OK

=== TEST 9: CMD_NOP ===
  PASS: NOP: state stayed IDLE, ready=1

=== TEST 10: Sequential read (4 bytes) ===
  PASS: Sequential read 00,01,02,03 OK

========================================
  TEST SUMMARY:  PASS=14  FAIL=0
  All tests PASSED
========================================
```

---

## 17. Что дальше

После того как все 10 тестов проходят — ядро `i2c_master_core` можно считать проверенным на базовом уровне. Можно переходить к следующему шагу проектирования:

1. **Написать прескалер** — делитель частоты, генерирующий `ena_i` из системного клока. Формула: `f_SCL = f_CLK / (4 × (PRESCALE + 1))`
2. **Написать регистровую обёртку** — набор memory-mapped регистров, через которые софт или процессор будут управлять ядром (CTRL, STATUS, CMD, TX_DATA, RX_DATA, PRESCALE)
3. **Написать секвенсер** — логику составных команд (например, «START + WRITE» одним регистровым доступом)
4. **Написать тестбенч для всей системы** — уже через регистровый интерфейс

Но фундамент — проверен. Можно строить дальше.
