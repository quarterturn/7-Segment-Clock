/* teeny led clock
 
 Keeps time using a DS3231 RTC chip.
 
 The clock is controlled via a three button interface.
 
 The display is 3 HP 5082-7433 LED bubble displays driven by a MAX7219
 
 Version: 1.0
 Author: Alexander Davis
 Hardwarwe: ATMEGA328
 
 Uses the TimeLord library http://www.swfltek.com/arduino/timelord.html for DST calculation.
 
 Digital pins used:
 3 INT/SQW from DS3231 (active-low, set internal pull-up)
 10, 11, 12 for the LCD
 6, 7, 8 for buttons (active-low; set internal pull-ups to avoid external pull-down)
 
 Analog pins used:
 5, 4 i2c for DS3231
 */

// for reading flash memory
#include <avr/pgmspace.h>
// for using atmega eeprom
#include <EEPROM.h>
// debounced button library
#include <Bounce.h>
// for 7 segment MAX7219 control
#include "LedControl.h"
// for using i2c interface
#include <Wire.h>

// for time calculations
#include <TimeLord.h>

// global constants
#define SQW_PIN 3
#define SERIAL_BAUD 9600

// menus
#define M_INTRO 0
#define M_SET_TIME 1
#define M_SET_DATE 2
#define M_SET_AL_T 3
#define M_SET_AL_D 4
#define M_SET_24_HR 5
#define M_SET_DST 6
#define M_SET_DONE 7
#define NUM_MENUS 7

#define SET_DEFAULTS 3
// to help remember setting positions
#define HOURS_SET 0
#define MINUTES_SET 1
#define SECONDS_SET 2
#define PM_SET 3
#define MONTHS_SET 0
#define DAYS_SET 1
#define YEARS_SET 2
#define DOW_SET 3
// to help remember for dst settings
#define DST_START_MON 0
#define DST_START_WEEK 1
#define DST_END_MON 2
#define DST_END_WEEK 3
#define DST_ENABLE 4
// to help remember the 12/24 hour settings
#define MODE_12_24_HOUR 0
// EEPROM memory locations for stored value
#define EE_DST_MON_START 0
#define EE_DST_WEEK_START 1
#define EE_DST_MON_END 2
#define EE_DST_WEEK_END 3
#define EE_TIME_MODE 4
#define EE_DST_ENABLE 5
#define EE_TIME_MODE 6
#define EE_AL_HR 7
#define EE_AL_MIN 8
#define EE_AL_MODE 9

// how long to display the date
// 5 seconds
#define DATE_DELAY 5000

// how long to wait between scroll steps
// 250 mS
#define SCROLL_DELAY 250

// left side window rightmost scroll limit in display buffer
#define DW_D_L_LIMIT 10
// left side window leftmost scroll limit in display buffer
#define DW_T_L_LIMIT 0

//i2c address of ds3231
#define DS3231_I2C_ADDRESS 0x68

// button setup - bounce objects
// 10 msec debounce interval
Bounce setButton = Bounce(6, 10);
Bounce decButton = Bounce(7, 10);
Bounce incButton = Bounce(8, 10);

// daylight savings time start and stop
byte dstMonStart;
byte dstDowStart = 1;
byte dstWeekStart;
byte dstMonEnd;
byte dstDowEnd = 1;
byte dstWeekEnd;
byte dstChangeHr = 23;
byte dstEnable = 1;
// timezone
int timezone;
// 12 hour mode flag
byte is12Hour;

// day of week
byte day;
  
// array offsets
// 0 second
// 1 minute
// 2 hour
// 3 day
// 4 month
// 5 year

// dst time
byte theTime[6];

// alarm hour
byte alarmHr;
// alarm minute
byte alarmMin;
// alarm mode
// 0 - off
// 2 - weekends
// 5 - weekdays
// 7 - every day
byte alarmMode;

// create a TimeLord object
TimeLord myLord;

/*
 LedControl pins
 pin 12 is connected to the DataIn 
 pin 11 is connected to the CLK 
 pin 10 is connected to LOAD 
 We have only a single MAX72XX.
 */
LedControl lc=LedControl(12,11,10,1);

// flag if time is ready per pin 3 interrupt
byte displayNow = 0;

// track if date should be shown
byte showDate = 0;

// 16 character display buffer
byte dispBuffer[18];

// there are 8 digits to the LED display
// therefore we use an 8 character window from the display buffer
// to display data
// left side of display window
byte dwL = 0;
// right side of display window
byte dwR = 7;

// delay for holding on the date display
int dateDelay = DATE_DELAY;

// for tracking time in delay loops
unsigned long previousMillis;

// string to be stored in flash at compile time
prog_char menu0[] PROGMEM = "TNYCHRON";
prog_char menu1[] PROGMEM = "SET TIME";
prog_char menu2[] PROGMEM = "SET DATE";
prog_char menu3[] PROGMEM = "SET AL T";
prog_char menu4[] PROGMEM = "SET AL D";
prog_char menu5[] PROGMEM = "SET 24HR";
prog_char menu6[] PROGMEM = "SET DST ";
prog_char menu7[] PROGMEM = "DONE    ";


// array of menu strings stored in flash
PROGMEM const char *menuStrSet[] = {
  menu0,
  menu1,
  menu2,
  menu3,
  menu4,
  menu5,
  menu6,
  menu7
};

// setup
void setup()
{
  
  // button setup
  // enable internal pull-ups
  pinMode(6, INPUT);
  digitalWrite(6, HIGH);
  pinMode(7, INPUT);
  digitalWrite(7, HIGH);
  pinMode(8, INPUT);
  digitalWrite(8, HIGH);
  
  // pin 3 set interrupt on SQW
  pinMode(SQW_PIN, INPUT);
  attachInterrupt(1, SQWintHandler, FALLING);
  
  // turn on the max7219
  lc.shutdown(0,false);
  // set the brightness to 12
  lc.setIntensity(0,12);
  // clear the display
  lc.clearDisplay(0);
}

  // timezone and dst info
  dstMonStart = EEPROM.read(EE_DST_MON_START);
  dstWeekStart = EEPROM.read(EE_DST_WEEK_START);
  dstMonEnd = EEPROM.read(EE_DST_MON_END);
  dstWeekEnd = EEPROM.read(EE_DST_WEEK_END);
  dstEnable = EEPROM.read(EE_DST_ENABLE);
  is12Hour = EEPROM.read(EE_TIME_MODE);
  timezone = EEPROM.read(EE_TIME_ZONE);
  if (timezone > 127)
  {
    timezone = (256 - timezone) * -1;
  }
  alarmHr = EEPROM.read(EE_AL_HR);
  alarmMin = EEPROM.read(EE_AL_MIN);
  alarmMode = EEPROM.read(EE_AL_MODE);
  
  // display version and contact info
  intro();

  // clear /EOSC bit
  // Sometimes necessary to ensure that the clock
  // keeps running on just battery power. Once set,
  // it shouldn't need to be reset but it's a good
  // idea to make sure.
  Wire.begin();
  Wire.beginTransmission(DS3231_I2C_ADDRESS); // address DS3231
  Wire.send(0x0E); // select register
  Wire.send(0b00011100); // write register bitmap, bit 7 is /EOSC
  Wire.endTransmission();

  // enable the SQW pin output
  // the function sets it to 1 HZ
  SQWEnable();
  
  // TimeLord library configuration
  // set timezone
  myLord.TimeZone(timezone * 60);
  // set dst rules
  myLord.DstRules(dstMonStart, dstWeekStart, dstMonEnd, dstWeekEnd, 60);
  
  // grab the date and time for use in sun calculations
  getDate();
  getTime();
  
  // convert time to dst if enabled
  if (dstEnable)
  {
    myLord.DST(theTime);
  }
  
  // compute the day of week
  day = myLord.DayOfWeek(theTime);
}

//---------------------------------------------------------------------------------------------//
// main loop
//---------------------------------------------------------------------------------------------//
void loop()
{
  // get the time and date
  // if pin 3 interrupt has triggered
  if (displayNow)
  {
    getTime();
    getDate();
    
    // convert time to dst if enabled
    if (dstEnable)
    {
      myLord.DST(theTime);
    }
    
    // compute the day of week
    day = myLord.DayOfWeek(theTime);
    
    // reset displayNow
    displayNow = 0;
    // load the new time and date into the display buffer
    updateBuffer();
  }
  
  // update the display from the buffer based on the display window
  updateDisplay(dwL, dwR);
  
  // grab now
  previousMillis = millis();
  // poll the buttons while waiting to update the display
  // after every SCROLL_DELYAY ms the display is updated
  // this provides a timing loop governing the display scroll speed
  // during a scroll from time to date and back
  while (millis() - previousMillis < SCROLL_DELAY)
  { 
    
    // get the time and date
    // if pin 3 interrupt has triggered
    if (displayNow)
    {
      getTime();
      getDate();
      // convert time to dst if enabled
      if (dstEnable)
      {
        myLord.DST(theTime);
      } 
      // compute the day of week
      day = myLord.DayOfWeek(theTime);
      // reset displayNow
      displayNow = 0;
      // load the new time and date into the display buffer
      updateBuffer();
    }
    
    // set button is pressed
    if (setButton.update())
    {
      if ((setButton.read()) == LOW)
      {
        // detach the interrupt 
        detachInterrupt(1);
        // enter set mode
        setMenu();
        // put the interrupt back on return
        attachInterrupt(1, SQWintHandler, FALLING);
      }
    }
    
    // if incButton is pressed
    // set the flag to start moving the display window rightward
    // on each pass through the timing loop
    if (incButton.update())
    {
      if (incButton.read()) == LOW)
      {
        if (showDate == 0)
        {
          showDate = 1;
        }
      }
    }
    
    // increment the display window if showDate is 1
    if (showDate == 1)
    {
      // if we have not reached the final rightmost position for the date
      // keep incrementing the window position
      if (dwL < DW_D_L_LIMIT)
      {
        dwL++;
        dwR++;
      }
      // if we have scrolled the display window all the way to the right
      // decrement the dateDelay on every pass through the timing loop
      // this will pause the display on the date
      if ((dwL == DW_D_L_LIMIT) && (dateDelay > 0))
      {
        dateDelay = dateDelay - 250;
      }
      if ((dwL = DW_D_L_LIMIT) && (dateDelay == 0))
      {
        dwL--;
        dwR--;
        showDate = 2;
      }
    }
    // decrement the display window if showDate is 2
    if (showDate == 2)
    {
      // if we have not reach the final leftmost position for the time
      // keep decrementing the window position
      if (dwL > DW_T_L_LIMIT)
      {
        dwL--;
        dwR--;
      }
      // if we reach the leftmost window limit for the time stop scrolling
      // and set showDate back to 0
      if (dwL == DW_T_L_LIMIT)
      {
        showDate = 0;
        dateDelay = DATE_DELAY;
      }
    }
  }     
}

//---------------------------------------------------------------------------------------------//
// function SQWintHandler
// sets displayNow on SQW pin 3 interrupt
// we keep it quick to minimize impact on other processes
//---------------------------------------------------------------------------------------------//
void SQWintHandler(void)
{
  displayNow = 1;
}

//---------------------------------------------------------------------------------------------//
// function setMenu
// displays the choices for setting the clock
//---------------------------------------------------------------------------------------------//
void setMenu()
{
  // default menu item is "set time"
  byte menuNum = 1;

  // default to time and date menu
  strcpy_P(dispBuffer, (char*)pgm_read_word(&(menuStrSet[menuNum])));

  // print the menu to the LED display
  updateDisplay(0, 7);


  // loop until exit
  while (1)
  {
    // down button goes to previous menu unless already there
    if (decButton.update() && (menuNum > 1))
    {
      if (decButton.read() == LOW)
      {
        menuNum--;
        strcpy_P(dispBuffer, (char*)pgm_read_word(&(menuStrSet[menuNum])));
        updateDisplay(0, 7);
      }
    }
    // up button goes to next menu unless already at last one
    if (incButton.update() && (menuNum < NUM_MENUS))
    {
      if (incButton.read() == LOW)
      {
        menuNum++;
        strcpy_P(dispBuffer, (char*)pgm_read_word(&(menuStrSet[menuNum])));
        updateDisplay(0, 7);
      }
    }
    // center button selects the current menu choice
    if (setButton.update())
    {
      if (setButton.read() == LOW)
      {
        switch(menuNum)
        {
          case M_SET_TIME:
            setTime();
            return;
            break;
          case M_SET_DATE:
            setDate();
            return;
            break;
          case M_SET_AL_T:
            setAlarmTime();
            return;
            break;
          case M_SET_AL_D:
            setAlarmDate();
            return;
            break;
          case M_SET_24_HR:
            set24Hr();
            return;
            break;     
          case M_SET_DST:
            setDst();
            return;
            break;
          case M_SET_DONE:
            return;
            break;
          default:
            return;
            break;
        }
      }
    } 
  } 
}


//---------------------------------------------------------------------------------------------//
// function setTime
// sets the time
//---------------------------------------------------------------------------------------------//
void setTime()
{
  // default to the first setting position
  byte setPos = 0;
  
  // get the time and date
  // so they will be in std time format
  getDate();
  getTime();

  // clear the lcd
  lcd.clear();

  // move the LCD cursor to home
  lcd.home();

  // print the set time prompt to the display
  lcd.print("SET TIME AND DATE");

  // move the cursor to the bottom line left side
  lcd.setCursor(0,1);

  // turn on the cursor
  lcd.cursor();

  // set the array indexes to the same position
  rowPos = 1;
  colPos = 0;

  // reset the array
  memset(menuValues, 0, (sizeof(menuValues)/sizeof(menuValues[0])));
  
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year

  // load the time and date values into the setting array
  // we will break them up into digits as that is how they are stored
  // tens hours
  menuValues[TENS_HOURS] = theTime[2] / 10;
  // ones hours
  menuValues[ONES_HOURS] = theTime[2] % 10;
  // tens minutes
  menuValues[TENS_MINUTES] = theTime[1] / 10;
  // ones minutes
  menuValues[ONES_MINUTES] = theTime[1] % 10;
  // tens seconds
  menuValues[TENS_SECONDS] = theTime[0] / 10;
  // ones seconds
  menuValues[ONES_SECONDS] = theTime[0] % 10;
  // tens month
  menuValues[TENS_MONTH] = theTime[4] / 10;
  // ones month
  menuValues[ONES_MONTH] = theTime[4] % 10;
  // tens day
  menuValues[TENS_DATE] = theTime[3] / 10;
  // ones day
  menuValues[ONES_DATE] = theTime[3] % 10;
  // tens year
  menuValues[TENS_YEAR] = theTime[5] / 10;
  // ones year
  menuValues[ONES_YEAR] = theTime[5] % 10;
  // the day of week
  menuValues[THE_DAY] = day;

  // write the current time and date data to the lcd
  displaySettingData(TIME_DATE);

  // time setting symbols
  lcd.setCursor(2,1);
  lcd.write(':');
  lcd.setCursor(5,1);
  lcd.write(':');
  lcd.setCursor(11,1);
  lcd.write('/');
  lcd.setCursor(14,1);
  lcd.write('/');
  lcd.setCursor(19,1);
  lcd.write('*');

  // move the cursor to the bottom line left side
  lcd.setCursor(0,1);

  // set currentValue to match the cursor position
  currentValue = menuValues[0];
  colPos = 0;

  while (1)
  {
    // if the down button is pressed,
    // decement the value so long as it is not out of range
    // and it is in a position allowed to be changed
    if ((downButton.update()) && (menuMask[TIME_DATE][colPos]))
    {
      if (downButton.read() == LOW)
      {
        decValue(TIME_DATE);
      }
    }

    // if the up button is pressed,
    // increment the value so long as it is not more than the value mask
    if (upButton.update() && menuMask[TIME_DATE][colPos])
    {
      if (upButton.read() == LOW)
      {
        // more logic to keep values in range
        switch (colPos)
        {
          case TENS_HOURS:
            if (checkHourValue())
            {
              currentValue++;
            }
            break;
          case ONES_HOURS:
            if (checkHourValue())
            {
              currentValue++;
            }
            break;
          case TENS_MINUTES:
            if (checkMinuteValue())
            {
              currentValue++;
            }
            break;
          case ONES_MINUTES:
            if (checkMinuteValue())
            {
              currentValue++;
            }
            break;
          case TENS_SECONDS:
            if (checkSecondValue())
            {
              currentValue++;
            }
            break;
          case ONES_SECONDS:
            if (checkSecondValue())
            {
              currentValue++;
            }
            break;
          case TENS_MONTH:
            if (checkMonthValue())
            {
              currentValue++;
            }
            break;
          case ONES_MONTH:
            if (checkMonthValue())
            {
              currentValue++;
            }
            break;
          case TENS_DATE:
            if (checkDayValue())
            {
              currentValue++;
            }
            break;
          case ONES_DATE:
            if (checkDayValue())
            {
              currentValue++;
            }
            break;
          case TENS_YEAR:
            if (checkYearValue())
            {
              currentValue++;
            }
            break;
          case ONES_YEAR:
            if (checkYearValue())
            {
              currentValue++;
            }
            break;
          case THE_DAY:
            if (currentValue < 7)
            {
              currentValue++;
            }
            break;
          case DONE:
            if (currentValue < 1)
            {
              currentValue++;
            }
            break;
          // otherwise don't do anything
          default:
            break;
        }
      }
      lcd.write(48 + currentValue);
      // move the cursor back since write moves it to the right
      lcd.setCursor(colPos,rowPos);
      // update the menu value array
      menuValues[colPos] = currentValue;
    }

    // go right on right button,
    // unless we are at the end of the array
    if (rightButton.update())
    {
      if (rightButton.read() == LOW)
      {
        moveRight(TIME_DATE);
      }
    }

    // go left on left button
    // unless we are at the end of the array
    if (leftButton.update())
    {
      if (leftButton.read() == LOW)
      {
        moveLeft(TIME_DATE);
      }
    }

    // if the middle button is pressed,
    // call function to test if we are on the set field
    // and return the status of 1 (set) or 0 (ignore)
    if ((centerButton.update()) && setButton(TIME_DATE))
    {
      if (centerButton.read() == LOW)
      {
        if (currentValue == 1)
        {
          rtcSetTimeDate();
        }
        lcd.noCursor();
        return;
      }
    }
  }
}


//---------------------------------------------------------------------------------------------//
// function setDstStartEnd
// sets the DST start and end dates
//---------------------------------------------------------------------------------------------//
void setDstStartEnd()
{
  byte setStatus = 0;

  // clear the lcd
  lcd.clear();

  // move the LCD cursor to home
  lcd.home();

  // print the set time prompt to the display
  lcd.print("SM SW SD EM EW ED ?");

  // move the cursor to the bottom line left side
  lcd.setCursor(0,1);

  // turn on the cursor
  lcd.cursor();

  // set the array indexes to the same position
  rowPos = 1;
  colPos = 0;

  // reset the array
  memset(menuValues, 0, (sizeof(menuValues)/sizeof(menuValues[0])));

  // load the time and date values into the setting array
  // we will break them up into digits as that is how they are stored
  // start tens month
  menuValues[DST_START_MON_TENS] =  dstMonStart / 10;
  // start ones month
  menuValues[DST_START_MON_ONES] = dstMonStart % 10;
  // start tens day
  menuValues[DST_START_DAY] = dstDowStart;
  // start ones day
  menuValues[DST_START_WEEK] = dstWeekStart;
  // end tens month
  menuValues[DST_END_MON_TENS] = dstMonEnd / 10;
  // end ones month
  menuValues[DST_END_MON_ONES] = dstMonEnd % 10;
  // end tens day
  menuValues[DST_END_DAY] = dstDowEnd;
  // end ones day
  menuValues[DST_END_WEEK] = dstWeekEnd;
  // enable
  menuValues[DST_ENABLE] = dstEnable;

  // write the current dst data to the lcd
  displaySettingData(DST_START_END);

  // time setting symbols
  lcd.setCursor(19,1);
  lcd.write('*');

  // move the cursor to the bottom line left side
  lcd.setCursor(0,1);

  // set currentValue to match the cursor position
  currentValue = menuValues[0];
  colPos = 0;

  while (1)
  {
    // if the down button is pressed,
    // decement the value so long as it is not out of range
    // and it is in a position allowed to be changed
    if ((downButton.update()) && (menuMask[DST_START_END][colPos]))
    {
      if (downButton.read() == LOW)
      {
        decValue(DST_START_END);
      }
    }

    // if the up button is pressed,
    // increment the value so long as it is not more than the value mask
    if (upButton.update() && menuMask[DST_START_END][colPos])
    {
      if (upButton.read() == LOW)
      {
        // more logic to keep values in range
        switch (colPos)
        {
          // limit start month to 12
          case DST_START_MON_TENS:
            if (((menuValues[DST_START_MON_TENS] * 10) + menuValues[DST_START_MON_ONES]) < 12)
            {
              currentValue++;
            }
            break;
          case DST_START_MON_ONES:
            if (((menuValues[DST_START_MON_TENS] * 10) + menuValues[DST_START_MON_ONES]) < 12)
            {
              currentValue++;
            }
            break;
            // limit end month to 12 
          case DST_START_WEEK:
            if (currentValue < 4)
            {
              currentValue++;
            }
            break;
          case DST_START_DAY:
            if (currentValue < 7)
            {
              currentValue++;
            }
            break;
          case DST_END_MON_TENS:
            if (((menuValues[DST_END_MON_TENS] * 10) + menuValues[DST_END_MON_ONES]) < 12)
            {
              currentValue++;
            }
            break;
          case DST_END_MON_ONES:
            if (((menuValues[DST_END_MON_TENS] * 10) + menuValues[DST_END_MON_ONES]) < 12)
            {
              currentValue++;
            }
            break;
          case DST_END_WEEK:
            if (currentValue < 4)
            {
              currentValue++;
            }
            break;
          case DST_END_DAY:
            if (currentValue < 7)
            {
              currentValue++;
            }
            break;
          case DST_ENABLE:
            if (currentValue < 1)
            {
              currentValue++;
            }
            break;
          case DONE:
            if (currentValue < 1)
            {
              currentValue++;
            }
            break;
            // otherwise do nothing
          default:
            currentValue++;
        }
        lcd.write(48 + currentValue);
        // move the cursor back since write moves it to the right
        lcd.setCursor(colPos,rowPos);
        // update the menu value array
        menuValues[colPos] = currentValue;
      }
    }

    // go right on right button,
    // unless we are at the end of the array
    if (rightButton.update())
    {
      if (rightButton.read() == LOW)
      {
        moveRight(DST_START_END);
      }
    }

    // go left on left button
    // unless we are at the end of the array
    if (leftButton.update())
    {
      if (leftButton.read() == LOW)
      {
        moveLeft(DST_START_END);
      }
    }

    // if the middle button is pressed,
    // call function to test if we are on the set field
    // and return the status of 1 (set) or 0 (ignore)
    if ((centerButton.update()) && setButton(DST_START_END))
    {
      if (centerButton.read() == LOW)
      {
        if (currentValue == 1)
        {
          // reconstruct the values
          dstMonStart = (menuValues[DST_START_MON_TENS] * 10) + menuValues[DST_START_MON_ONES];
          dstDowStart = menuValues[DST_START_DAY];
          dstWeekStart =  menuValues[DST_START_WEEK];
          dstMonEnd = (menuValues[DST_END_MON_TENS] * 10) + menuValues[DST_END_MON_ONES];
          dstDowEnd = menuValues[DST_END_DAY];
          dstWeekEnd =  menuValues[DST_END_WEEK];
          dstEnable = menuValues[DST_ENABLE];
          
          // write the dst change info to the eeprom
          EEPROM.write(EE_DST_MON_START, dstMonStart);
          EEPROM.write(EE_DST_DOW_START, dstDowStart);
          EEPROM.write(EE_DST_WEEK_START, dstWeekStart);
          EEPROM.write(EE_DST_MON_END, dstMonEnd);
          EEPROM.write(EE_DST_DOW_END, dstDowEnd);
          EEPROM.write(EE_DST_WEEK_END, dstWeekEnd);
          // update dst enable flag
          dstEnable = menuValues[DST_ENABLE];
          // write the dst enable flag to eeprom
          EEPROM.write(EE_DST_ENABLE, dstEnable);
  
          myLord.TimeZone(timezone * 60);
          myLord.DstRules(dstMonStart, dstWeekStart, dstMonEnd, dstWeekEnd, 60);
        }
      }             
      // turn off the cursor
      lcd.noCursor();
      // exit the set tz, long and lat function
      return;
    } 
  }
}


//---------------------------------------------------------------------------------------------//
// function set1224Mode
// displays the choices for 12/24 hour display mode
//---------------------------------------------------------------------------------------------//
void set1224Mode()
{
  byte setStatus = 0;

  // clear the lcd
  lcd.clear();

  // move the LCD cursor to home
  lcd.home();
  
  // reset the array
  memset(menuValues, 0, (sizeof(menuValues)/sizeof(menuValues[0])));

  // print the set time prompt to the display
  lcd.print("USE 12 HOUR MODE");

  // move the cursor to the bottom line left side
  lcd.setCursor(0,1);

  // turn on the cursor
  lcd.cursor();

  // set the array indexes to the same position
  rowPos = 1;
  colPos = 0;
  
  // write the current data to the display 
  lcd.setCursor(12,1);
  if (is12Hour)
  {
    lcd.print("YES");
    menuValues[MODE_12_24_HOUR] = 1;
  }
  else
  {
    lcd.print("NO ");
    menuValues[MODE_12_24_HOUR] = 0;
  }
  lcd.setCursor(19,1);
  lcd.print('*');

  // move the cursor to the bottom line left side
  lcd.setCursor(0,1);

  // set currentValue to match the cursor position
  currentValue = menuValues[0];
  colPos = 0;

  while (1)
  {
    // if the down button is pressed,
    // decement the value so long as it is not out of range
    // and it is in a position allowed to be changed
    if ((downButton.update()) && (menuMask[SET_12_24_MODE][colPos]))
    {
      if (downButton.read() == LOW)
      {
        // more logic to keep values in range
        switch (colPos)
        {    
          // 12 hour enable position
          case MODE_12_24_HOUR:
            if (currentValue > 0)
            {
              currentValue--;
              lcd.print("NO ");
              lcd.setCursor(colPos,rowPos);
            }
            break;
          // set or not position - done
          case DONE:
            if (currentValue > 0)
            {
              currentValue++;
              lcd.print("0");
              lcd.setCursor(colPos,rowPos);
            }
            break;
          // otherwise do nothing
          default:
            break;
        }
      }
    }
    
    // if the up button is pressed,
    // increment the value so long as it is not more than the value mask
    if (upButton.update() && menuMask[SET_12_24_MODE][colPos])
    {
      if (upButton.read() == LOW)
      {
        // more logic to keep values in range
        switch (colPos)
        {    
          // 12 hour enable position
          case MODE_12_24_HOUR:
            if (currentValue < 1)
            {
              currentValue++;
              lcd.print("YES");
              lcd.setCursor(colPos,rowPos);
            }
            break;
          // set or not position - done
          case DONE:
            if (currentValue < 1)
            {
              currentValue++;
              lcd.print("1");
              lcd.setCursor(colPos,rowPos);
            }
            break;
          // otherwise do nothing
          default:
            break;
        }
      }
    }
 
    // go right on right button,
    // unless we are at the end of the array
    if (rightButton.update())
    {
      if (rightButton.read() == LOW)
      {
        moveRight(SET_12_24_MODE);
      }
    }

    // go left on left button
    // unless we are at the end of the array
    if (leftButton.update())
    {
      if (leftButton.read() == LOW)
      {
        moveLeft(SET_12_24_MODE);
      }
    }

    // if we are on the set position
    // middle button sets if 1 and discards if 0
    if ((centerButton.update()) && setButton(SET_12_24_MODE))
    {
      if (centerButton.read() == LOW)
      {
        if (currentValue == 1)
        {
          is12Hour = menuValues[MODE_12_24_HOUR];
          // write the values to the eeprom
          EEPROM.write(EE_TIME_MODE, is12Hour);
          // turn off the cursor
          lcd.noCursor();
          // exit the set display schedule
          return;       
        }             
        // turn off the cursor
        lcd.noCursor();
        // exit the set display schedule menu
        return;
      }
    } 
    menuValues[colPos] = currentValue;   
  }
}


//---------------------------------------------------------------------------------------------//
// function setMenu
// displays the choices for setting the clock
//---------------------------------------------------------------------------------------------//
void setMenu()
{
  char currentString[20];
  byte menuNum = 0;
  
  // turn on the lcd
  lcd.display();

  // clear the lcd
  lcd.clear();

  // move the LCD cursor to home
  lcd.home();

  // default to time and date menu
  strcpy_P(currentString, (char*)pgm_read_word(&(menuStrSet[menuNum])));

  // print the menu to the LCD
  lcd.print(currentString);


  // loop until exit
  while (1)
  {
    // down button goes to previous menu unless already there
    if (downButton.update() && (menuNum > 0))
    {
      if (downButton.read() == LOW)
      {
        menuNum--;
        strcpy_P(currentString, (char*)pgm_read_word(&(menuStrSet[menuNum])));
        lcd.clear();
        lcd.home();
        lcd.print(currentString);
      }
    }
    // up button goes to next menu unless already at last one
    if (upButton.update() && (menuNum < NUM_MENUS))
    {
      if (upButton.read() == LOW)
      {
        menuNum++;
        strcpy_P(currentString, (char*)pgm_read_word(&(menuStrSet[menuNum])));
        lcd.clear();
        lcd.home();
        lcd.print(currentString);
      }
    }
    // center button selects the current menu choice
    if (centerButton.update())
    {
      if (centerButton.read() == LOW)
      {
        switch(menuNum)
        {
          // set time and date menu
          // 
        case TIME_DATE:
          setTimeDate();
          lcd.clear();
          return;
          break;
        case TZ_LONG_LAT:
          setTzLongLat();
          lcd.clear();
          return;
          break;
        case DST_START_END:
          setDstStartEnd();
          lcd.clear();
          return;
          break;
        case DISP_SCHED:
          setDispSched();
          lcd.clear();
          return;
          break;
        case SET_12_24_MODE:
          set1224Mode();
          lcd.clear();
          return;
          break;
        case SET_DEFAULTS:
          setDefaults();
          lcd.clear();
          return;
          break;
          // exit setting mode
        case 6:
          lcd.clear();
          return;
          break;
        }
      }
    } 
  } 
}

//---------------------------------------------------------------------------------------------//
// function rtcSetTimeDate
// sets the time and date on the DS3231 RTC
// uses the global menuValues for index TIME_DATE to re-assemble each digit into the data
//---------------------------------------------------------------------------------------------//
void rtcSetTimeDate()
{ 
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year
  
  // reassemble the values
  theTime[2] = 10 * menuValues[TENS_HOURS] + menuValues[ONES_HOURS];
  theTime[1] = 10 * menuValues[TENS_MINUTES] + menuValues[ONES_MINUTES];
  theTime[0] = 10 * menuValues[TENS_SECONDS] + menuValues[ONES_SECONDS];
  theTime[4] = 10 * menuValues[TENS_MONTH] + menuValues[ONES_MONTH];
  theTime[3] = 10 * menuValues[TENS_DATE] + menuValues[ONES_DATE];
  theTime[5] = 10 * menuValues[TENS_YEAR] + menuValues[ONES_YEAR];
  day = menuValues[THE_DAY];

  // send the values to the RTC
  setDate();
  setTime();
  
  // set the sunRise array
  sunRise[0] = 0;
  sunRise[1] = 0;
  sunRise[2] = 0;
  sunRise[3] = theTime[3];
  sunRise[4] = theTime[4];
  sunRise[5] = theTime[5];
 
  // call the SunRise method
  sunWillRise = myLord.SunRise(sunRise);
  
  // set the sunSet array
  sunSet[0] = 0;
  sunSet[1] = 0;
  sunSet[2] = 0;
  sunSet[3] = theTime[3];
  sunSet[4] = theTime[4];
  sunSet[5] = theTime[5];
  
  // call the sunSet method
  myLord.SunSet(sunSet);
  
  // call the MoonPhase method
  moonPhase = myLord.MoonPhase(sunRise);
  
  // calculate noon from sunrise and sunset times
  calculateNoon();
  
  // convert time to dst if enabled
  if (dstEnable)
  {
    myLord.DST(theTime);
    myLord.DST(sunRise);
    myLord.DST(sunSet);
    myLord.DST(theNoon);
  }
}

//---------------------------------------------------------------------------------------------//
// function setDate
// sets the date on the DS3231 RTC
// uses the globals day date month year
//---------------------------------------------------------------------------------------------//
void setDate()
{
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year
  
  Wire.beginTransmission(DS3231_I2C_ADDRESS);
  Wire.send(3);
  Wire.send(decToBcd(day));
  Wire.send(decToBcd(theTime[3]));
  Wire.send(decToBcd(theTime[4]));
  Wire.send(decToBcd(theTime[5]));
  Wire.endTransmission();
}

//---------------------------------------------------------------------------------------------//
// function getDate
// gets the date from the DS3231 RTC
// uses the globals day date month year
//---------------------------------------------------------------------------------------------//
void getDate()
{
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year
  
  Wire.beginTransmission(DS3231_I2C_ADDRESS);
  Wire.send(3); //set register to 3 (day)
  Wire.endTransmission();
  Wire.requestFrom(DS3231_I2C_ADDRESS, 4); //get 5 bytes (day,date,month,year,control)
  while(Wire.available())
  {
    day = bcdToDec(Wire.receive());
    theTime[3] = bcdToDec(Wire.receive());
    theTime[4] = bcdToDec(Wire.receive());
    theTime[5] = bcdToDec(Wire.receive());
  }
}

//---------------------------------------------------------------------------------------------//
// function setTime
// sets the time on the DS3231 RTC
// uses the global theTime[]
//---------------------------------------------------------------------------------------------//
void setTime()
{
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year
  
  Wire.beginTransmission(DS3231_I2C_ADDRESS);
  Wire.send(0);
  Wire.send(decToBcd(theTime[0]));
  Wire.send(decToBcd(theTime[1]));
  Wire.send(decToBcd(theTime[2]));
  Wire.endTransmission();
}

//---------------------------------------------------------------------------------------------//
// function getTime
// gets the time from the DS3231 RTC
// uses the global theTime[]
//---------------------------------------------------------------------------------------------//
void getTime()
{
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year
  
  Wire.beginTransmission(DS3231_I2C_ADDRESS);
  Wire.send(0); //set register to 0
  Wire.endTransmission();
  Wire.requestFrom(DS3231_I2C_ADDRESS, 3); //get 3 bytes (seconds, minutes, hours)
  while(Wire.available())
  {
    theTime[0] = bcdToDec(Wire.receive() & 0x7f);
    theTime[1] = bcdToDec(Wire.receive());
    theTime[2] = bcdToDec(Wire.receive() & 0x3f);
  }
}

//---------------------------------------------------------------------------------------------//
// function displayTimeAndDate
// displays the time and date on the first line of the LCD
// uses the globals theTime[]
//---------------------------------------------------------------------------------------------//
void displayTimeAndDate()
{
  char buf[12];
  
  byte tmpMin,
       tmpHr;

  // get the time
  getTime();
  // get the date
  getDate();
  
  // convert time to dst if enabled
  if (dstEnable)
  {
    myLord.DST(theTime);
  }

  // start at upper left
  lcd.setCursor(0, 0);
  
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year
  
  // test for display mode change time
  // if you set them all the same you should stay in bright mode
  // off
  if ((theTime[1] == 0) && (theTime[0] == 0) && (theTime[2] == offHour))
  {
    lcd.noDisplay();
  }  
  // dim
  if ((theTime[1] == 0) && (theTime[0] == 0) && (theTime[2] == dimHour))
  {
    lcd.display();
    lcd.vfdDim(3);
  }
  // bright
  if ((theTime[1] == 0) && (theTime[0] == 0) && (theTime[2] == brightHour))
  {
    // turn on the display
    lcd.display();
    lcd.vfdDim(0);
  }
  
  tmpHr = theTime[2];
  // convert to 12 hour time if set
  if (is12Hour)
  {
    // convert 0 to 12
    if (tmpHr == 0)
    {
      tmpHr = 12;
    }
    // if greater than 12 subtract 12
    if (tmpHr > 12)
    {
      tmpHr = tmpHr - 12;
    }
  }
  
  // print the hour
  // pad with a zero if less than ten hours 
  // and 12 hour time is not set 
  if ((tmpHr < 10) && !(is12Hour))
  {
    lcd.print("0");
  }
  // if 12 hour time is set pad with space
  // if the tens hour is less than one
  if ((tmpHr < 10) && (is12Hour))
  {
    lcd.print(" ");
  }
    
  lcd.print(itoa(tmpHr, buf, 10));
  lcd.print(":");

  // print the minutes
  // pad with a zero if less than ten minutes
  if (theTime[1] < 10)
  {
    lcd.print("0");
  }
  lcd.print(itoa(theTime[1], buf, 10));
  lcd.print(":");

  // print the seconds
  // pad with a zero if less than ten seconds
  if (theTime[0] < 10)
  {
    lcd.print("0");
  }
  lcd.print(itoa(theTime[0], buf, 10));

  lcd.setCursor(9, 0);

  // print the day of the week
  switch (day) {
  case 1:
    lcd.print("Su");
    break;
  case 2:
    lcd.print("Mo");
    break;
  case 3:
    lcd.print("Tu");
    break;
  case 4:
    lcd.print("We");
    break;
  case 5:
    lcd.print("Th");
    break;
  case 6:
    lcd.print("Fr");
    break;
  case 7:
    lcd.print("Sa");
    break;
  }

  lcd.setCursor(12,0);

  // print the month
  // pad with a zero if less than ten
  if (theTime[4] < 10)
  {
    lcd.print("0");
  }  
  lcd.print(itoa(theTime[4], buf, 10));
  lcd.print("/");

  // print the date
  // pad with a zero if less than ten
  if (theTime[3] < 10)
  {
    lcd.print("0");
  }
  lcd.print(itoa(theTime[3], buf, 10)); 

  // I decided not to have the year displayed
  // uncomment below if you want it

  //lcd.print("/"); 

  // print the year
  // pad with a zero if less than ten
  //  if (year < 10)
  //  {
  //    lcd.print("0");
  //  }
  //  lcd.print(itoa(year, buf, 10));
  //  Serial.println("Done displaying time");
  
  // move the cursor to the bottom line left side
  lcd.setCursor(0,1);
  
  // update the sunrise, noon, sunset and moon at 0000:01
  if ((theTime[2] == 0) && (theTime[2] == 0) && (theTime[0] == 1))
  {
    // set the sunRise array
    sunRise[0] = 0;
    sunRise[1] = 0;
    sunRise[2] = 0;
    sunRise[3] = theTime[3];
    sunRise[4] = theTime[4];
    sunRise[5] = theTime[5];
    
    // call the SunRise method and get the return result
    // so we can tell if the sun actually rises
    sunWillRise = myLord.SunRise(sunRise);
    
    // set the sunSet array
    sunSet[0] = 0;
    sunSet[1] = 0;
    sunSet[2] = 0;
    sunSet[3] = theTime[3];
    sunSet[4] = theTime[4];
    sunSet[5] = theTime[5];
    
    // call the sunSet method
    myLord.SunSet(sunSet);
    
    // call the MoonPhase method
    moonPhase = myLord.MoonPhase(sunRise);
    
    // calculate noon
    calculateNoon();
    
    // convert time to dst if enabled
    if (dstEnable)
    {
      myLord.DST(sunRise);
      myLord.DST(sunSet);
      myLord.DST(theNoon);
    }
  }
  
  // print the sunrise, sunset and noon if the sun rises
  if (sunWillRise)
  {
    // sunrise up triangle
    // theTime[2]
    lcd.write(31);
    tmpHr = sunRise[2];
    
    // convert to 12 hour time if set
    if (is12Hour)
    {
      // convert 0 to 12
      if (tmpHr == 0)
      {
        tmpHr = 12;
      }
      // if greater than 12 subtract 12
      if (tmpHr > 12)
      {
        tmpHr = tmpHr - 12;
      }
    }
    
    if ((tmpHr < 10) && !(is12Hour))
    {
      lcd.print('0');
    }
    if ((tmpHr < 10) && (is12Hour))
    {
      lcd.print(" ");
    }
    
    lcd.print(tmpHr, DEC);
    // minutes
    tmpMin = sunRise[1];
    if (tmpMin < 10)
    {
      lcd.print('0');
    }
    lcd.print(tmpMin, DEC);
    
    // space
    lcd.write(' ');
    
    // sunset down triangle
    // theTime[2]
    lcd.write(28);
    tmpHr = sunSet[2];
    
    // convert to 12 hour time if set
    if (is12Hour)
    {
      // convert 0 to 12
      if (tmpHr == 0)
      {
        tmpHr = 12;
      }
      // if greater than 12 subtract 12
      if (tmpHr > 12)
      {
        tmpHr = tmpHr - 12;
      }
    }
    
    if ((tmpHr < 10) && !(is12Hour))
    {
      lcd.print('0');
    }
    if ((tmpHr < 10) && (is12Hour))
    {
      lcd.print(" ");
    }
    
    lcd.print(tmpHr, DEC);
    // minutes
    tmpMin = sunSet[1];
    if (tmpMin < 10)
    {
      lcd.print('0');
    }
    lcd.print(tmpMin, DEC);
    
    // space
    lcd.print(' ');
    
    // noon
    lcd.write(148);
   
    tmpHr = theNoon[2];
    
    // convert to 12 hour time if set
    if (is12Hour)
    {
      // convert 0 to 12
      if (tmpHr == 0)
      {
        tmpHr = 12;
      }
      // if greater than 12 subtract 12
      if (tmpHr > 12)
      {
        tmpHr = tmpHr - 12;
      }
    }
    
    if ((tmpHr < 10) && !(is12Hour))
    {
      lcd.print('0');
    }
    if ((tmpHr < 10) && (is12Hour))
    {
      lcd.print(" ");
    }
    
    lcd.print(tmpHr, DEC);
    
    // minutes
    if (theNoon[1] < 10)
    {
      lcd.print('0');
    }
    lcd.print(theNoon[1], DEC);    
  }
  // otherwise signify the sun is not rising
  else
  {
    lcd.write(31);
    lcd.print("--:-- ");
    lcd.write(28);
    lcd.print("--:-- ");
    lcd.write(148);
    lcd.print("--:-- ");
  }
  
  // space
  lcd.print(' ');
  
  // moon phase
  if (moonPhase == 0)
  {
    lcd.write(149);
  }
  if ((moonPhase < 0.15) && (moonPhase > 0))
  {
    lcd.write(24);
  }
  if ((moonPhase < 0.25) && (moonPhase >= 0.15))
  {
    lcd.write(23);
  }
  if ((moonPhase < 0.35) && (moonPhase >= 0.25))
  {
    lcd.write(22);
  }
  if ((moonPhase < 0.45) && (moonPhase >= 0.35))
  {
    lcd.write(21);
  }
  if ((moonPhase < 0.55) && (moonPhase >= 0.45))
  {
    lcd.write(20);
  }
  if ((moonPhase < 0.65) && (moonPhase >= 0.55))
  {
    lcd.write(19);
  }
  if ((moonPhase < 0.75) && (moonPhase >= 0.65))
  {
    lcd.write(18);
  }
  if ((moonPhase < 0.85) && (moonPhase >= 0.75))
  {
    lcd.write(17);
  }
  if ((moonPhase < 0.95) && (moonPhase >= 0.85))
  {
    lcd.write(16);
  }
  if (moonPhase >= 0.95)
  {
    lcd.write(149);
  }
}

//---------------------------------------------------------------------------------------------//
// function decToBcd
// Convert normal decimal numbers to binary coded decimal
//---------------------------------------------------------------------------------------------//
byte decToBcd(byte val)
{
  return ( (val/10*16) + (val%10) );
}

//---------------------------------------------------------------------------------------------//
// function bdctoDec
// Convert binary coded decimal to normal decimal numbers
//---------------------------------------------------------------------------------------------//
byte bcdToDec(byte val)
{
  return ( (val/16*10) + (val%16) );
}

//---------------------------------------------------------------------------------------------//
// function SQWEnable
// enables output on the SQW pin
//---------------------------------------------------------------------------------------------//
void SQWEnable()
{
  Wire.beginTransmission(DS3231_I2C_ADDRESS);
  Wire.send(0x0e);
  Wire.send(0);
  Wire.endTransmission();
}


//---------------------------------------------------------------------------------------------//
// function setDefaults
// sets default values for stored settings in the eeprom
//---------------------------------------------------------------------------------------------//
void setDefaults()
{
  int defLat = 3587;
  int defLong = -7878;
  
  // timezone and dst info
  EEPROM.write(EE_TIME_ZONE, -5);
  EEPROM.write(EE_DST_MON_START, 3);
  EEPROM.write(EE_DST_DOW_START, 1);
  EEPROM.write(EE_DST_WEEK_START, 1);
  EEPROM.write(EE_DST_MON_END, 10);
  EEPROM.write(EE_DST_DOW_END, 1);
  EEPROM.write(EE_DST_WEEK_END, 1);
  EEPROM.write(EE_DST_CHANGE_HOUR, 2);
  EEPROM.write(EE_DST_ENABLE, 0);
  
      
  // set regular display mode
  EEPROM.write(EE_BIG_MODE, 0);
  bigMode = 0;
  
  // set the latitude
  bu = highByte(defLat);
  bl = lowByte(defLat);  
  EEPROM.write(EE_LAT_U, bu);
  EEPROM.write(EE_LAT_L, bl);
  // set the longitude
  bu = highByte(defLong);
  bl = lowByte(defLong);
  EEPROM.write(EE_LONG_U, bu);
  EEPROM.write(EE_LONG_L, bl);
  // set the bright hour
  EEPROM.write(EE_BRIGHT_HR, 6);
  // set the dim hour
  EEPROM.write(EE_DIM_HR, 21);
  // set the off hour
  EEPROM.write(EE_OFF_HR, 1);

  // automatic dst changeover flag
  EEPROM.write(EE_DST_ENABLE, 1);
  
  // set 24-hour mode
  EEPROM.write(EE_TIME_MODE, 0);
  
  lcd.clear();
  lcd.home();
  lcd.print("DEFAULTS SET");
  delay(2000);
  lcd.clear();
}

//---------------------------------------------------------------------------------------------//
// function calculateNoon
// calculates noon from sunRise and sunSet
//---------------------------------------------------------------------------------------------//
void calculateNoon()
{
  int setMin,
      riseMin,
      aMin;
      
  // sunset time in minutes from 0000
  setMin = sunSet[2] * 60 + sunSet[1];
 
  // sunrise time in minutes from 0000
  riseMin = sunRise[2] * 60 + sunRise[1];
 
  // take the average between sunrise and sunset
  aMin = (setMin + riseMin) / 2;
  
  theNoon[2] = aMin / 60;
  theNoon[1] = aMin % 60;
  
  // fill in the date from sunRise
  theNoon[3] = sunRise[3];
  theNoon[4] = sunRise[4];
  theNoon[5] = sunRise[5];
  
}


//---------------------------------------------------------------------------------------------//
// function intro()
// displays version info
//---------------------------------------------------------------------------------------------//
 void intro()
{ 
  // grab the intro from flash
  strcpy_P(dispBuffer, (char*)pgm_read_word(&(menuStrSet[0])));
  // display it from the buffer
  updateDisplay(0, 7);
  delay(5000); 
}

//---------------------------------------------------------------------------------------------//
// function updateBuffer()
// updates the display buffer with the time and date

//---------------------------------------------------------------------------------------------//
void updateBuffer()
{
  byte tmpHr;
  
  tmpHr = theTime[2];
  // convert to 12 hour time if set
  if (is12Hour)
  {
    // convert 0 to 12
    if (tmpHr == 0)
    {
      tmpHr = 12;
    }
    // if greater than 12 subtract 12
    if (tmpHr > 12)
    {
      tmpHr = tmpHr - 12;
    }
  }
  
  // tens hour
  displayBuffer[0] = tmpHr / 10;
  // ones hour
  // add 128 to indicate dp is on
  displayBuffer[1] = (tmpHr % 10) + 128;  
  // if 12 hour time is set pad with space
  // if the tens hour is less than one
  if ((tmpHr < 10) && (is12Hour))
  {
    displayBuffer[0] = ' ';
  }

  // tens minute
  displayBuffer[2] = theTime[1] / 10;
  // ones minute
  // add 128 to indicate dp is on
  displayBuffer[3] = (theTime[1] % 10) + 128;

  // tens second
  displayBuffer[4] = theTime[0] / 10;
  // ones second
  displayBuffer[5] = theTime[0] % 10

  // a space
  displayBuffer[6] = ' ';
  
  // am/pm and alarm indicator
  if (is12Hour)
  {
    if (theTime[2] < 12)
    {
      if (alarmMode > 0)
      {
        displayBuffer[7] = 'P' + 128;
      }
      else
      {
        displayBuffer[7] = 'P';
      }
    }
    else
    {
      if (alarmMode > 0)
      {
        displayBuffer[7] = 'A' + 128;
      }
      else
      {
        displayBuffer[7] = 'A';
      }
    }
  else
  {
    if (alarmMode > 0)
    {
      displayBuffer[7] = '.';
    }
    else
    {
      displayBuffer[7] = ' ';
    }
  }
  
  // two more spaces
  displayBuffer[8] = ' ';
  displayBuffer[9] = ' ';
  
  // tens month
  displayBuffer[10] = theTime[4] / 10;
  // ones month
  // add 128 to indicate dp is on
  displayBuffer[11] = (theTime[4] % 10) + 128;
  
  // tens day
  displayBuffer[12] = theTime[3] / 10;
  // ones day
  // add 128 to indicate dp is on
  displayBuffer[13] = (theTime[3] % 10) + 128;
  
  // tens year
  displayBuffer[14] = theTime[5] / 10;
  // ones year
  displayBuffer[15] = theTime[5] % 10;
  
  // a space
  displayBuffer[16] = ' ';
  
  // day of week 1-7
