//! A Nucleo-64 F401 example that dumps flash contents to a USART.
//!
//! The flash chip is connected to the canonical SPI port on the Arduino-style
//! connector:
//!
//! *  SCK = D13 = PA5
//! * MISO = D12 = PA6
//! * MOSI = D11 = PA7
//!
//! The data is dumped in hexadecimal format through USART2 (TX = D1 = PA2).

#![no_std]
#![no_main]

extern crate panic_semihosting;

use cortex_m::prelude::_embedded_hal_serial_Write as Write;
use cortex_m_rt::entry;
use cortex_m_semihosting::hprintln;
use embedded_hal::spi::MODE_0;
use stm32f4xx_hal::gpio::GpioExt;
use stm32f4xx_hal::pac;
use stm32f4xx_hal::prelude::*;
use stm32f4xx_hal::rcc::RccExt;
use stm32f4xx_hal::serial::{self, SerialExt};
use stm32f4xx_hal::spi::SpiExt;
use stm32f4xx_hal::time::Bps;

use w25q::series25::Flash;

use core::fmt::Write as _;

/// Flash chip size in Mbit.
const MEGABITS: u32 = 4;

/// Serial baudrate.
const BAUDRATE: u32 = 912600;

/// Size of the flash chip in bytes.
const SIZE_IN_BYTES: u32 = (MEGABITS * 1024 * 1024) / 8;

fn print<'a, E>(buf: &[u8], w: &'a mut (dyn Write<u8, Error = E> + 'static)) {
    for c in buf {
        write!(w, "{:02X}", c).unwrap();
    }
    writeln!(w).unwrap();
}

#[entry]
fn main() -> ! {
    let periph = pac::Peripherals::take().unwrap();
    let clocks = periph.RCC.constrain().cfgr.freeze();
    let gpioa = periph.GPIOA.split();

    let cs = {
        let mut cs = gpioa.pa9.into_push_pull_output();
        cs.set_high(); // deselect
        cs
    };

    let spi = {
        let sck = gpioa.pa5.into_alternate();
        let miso = gpioa.pa6.into_alternate();
        let mosi = gpioa.pa7.into_alternate();

        periph.SPI1.spi((sck, miso, mosi), MODE_0, 1.MHz(), &clocks)
    };

    let mut serial = {
        let tx = gpioa.pa2.into_alternate();

        let config = serial::config::Config {
            baudrate: Bps(BAUDRATE),
            ..Default::default()
        };
        periph.USART2.tx(tx, config, &clocks).unwrap()
    };

    let mut flash = Flash::init(spi, cs).unwrap();
    let id = flash.read_jedec_id().unwrap();
    hprintln!("{:?}", id);

    let mut addr = 0;
    const BUF: usize = 32;
    let mut buf = [0; BUF];

    while addr < SIZE_IN_BYTES {
        flash.read(addr, &mut buf).unwrap();
        print(&buf, &mut serial);

        addr += BUF as u32;
    }

    hprintln!("DONE");

    loop {}
}
