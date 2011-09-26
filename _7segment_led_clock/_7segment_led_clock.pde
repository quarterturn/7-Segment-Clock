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
#define M_SET_AL 3
#define M_SET_24_HR 4
#define M_SET_DST 5
#define M_SET_DONE 6
#define NUM_MENUS 6

#define SET_DEFAULTS 3
// to help remember time setting positions
#define HOURS_SET 0
#define MINUTES_SET 1
#define SECONDS_SET 2
#define PM_SET 3
// to help remember date setting positions
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
prog_char menu3[] PROGMEM = "SET AL  ";
prog_char menu4[] PROGMEM = "SET 24HR";
prog_char menu5[] PROGMEM = "SET DST ";
prog_char menu6[] PROGMEM = "DONE    ";


// array of menu strings stored in flash
PROGMEM const char *menuStrSet[] = {
  menu0,
  menu1,
  menu2,
  menu3,
  menu4,
  menu5,
  menu6
};

// setup
void setup(void)
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
  getDateRtc();
  getTimeRtc();
  
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
void loop(void)
{
  // get the time and date
  // if pin 3 interrupt has triggered
  if (displayNow)
  {
    getTimeRtc();
    getDateRtc();
    
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
      getTimeRtc();
      getDateRtc();
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
      if (setButton.read() == LOW)
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
      if (incButton.read() == LOW)
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
void setMenu(void)
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
          case M_SET_AL:
            setAlarm();
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
void setTime(void)
{
  // default to the first setting position
  byte setPos = 0;
  // default to blink off
  byte blinkOff = 1;
  // signal to break out of an outer loop from an inner loop
  byte breakout = 0;
  
  getTimeRtc();
  getDateRtc();
    
  // convert time to dst if enabled
  if (dstEnable)
  {
    myLord.DST(theTime);
  }
    
  // compute the day of week
  day = myLord.DayOfWeek(theTime);

  // load the new time and date into the display buffer
  updateBuffer();
  // update the display
  updateDisplay(0, 7);
 
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year

  while (1)
  {
    // grab now
    previousMillis = millis()
    // loop until SCROLL_DELAY has elapsed
    // toggle blinkOff and if true, blank the current setPos
    // this will blink the value to be set
    while (millis() - previousMillis < SCROLL_DELAY)
    {
      // the set button moves to the next value to be set
      // from left to right
      if (setButton.update())
      {
        if (setButton.read() == LOW)
        {
          // if we are already at the seconds position
          // set the time and exit
          if (setPos == 2)
  	  {
  	    setTimeRtc();
  	    // set the return flag
            breakout = 1;
            // exit the timing loop
            break;
  	  }
  	  // otherwise go to the next position
  	  else
  	  {
  	    setPos++;
  	  }
        }
      }
  
      // if the up button is pressed,
      // increment the value
      if (incButton.update())
      {
        if (incButton.read() == LOW)
        {
          // test each value and keep in range
          switch (setPos)
          {
            case HOURS_SET:
              if (theTime[2] < 23)
              {
                theTime[2] = theTime[2] + 1;
              }
              break;
            case MINUTES_SET:
              if (theTime[1] < 59)
              {
                theTime[1] = theTime[1] + 1;
              }
              break;
            case SECONDS_SET:
              if (theTime[0] < 59)
              {
                theTime[0] = theTime[0] + 1;
              }
              break;
            // otherwise don't do anything
            default:
              break;
          }
        }    
      }
  
      // if the down button is pressed,
      // decrement the value
      if (decButton.update())
      {
        if (decButton.read() == LOW)
        {
          // test each value and keep in range
          switch (setPos)
          {
            case HOURS_SET:
              if (theTime[2] > 0)
              {
                theTime[2] = theTime[2] - 1;
              }
              break;
            case MINUTES_SET:
              if (theTime[1] < 0)
              {
                theTime[1] = theTime[1] - 1;
              }
              break;
            case SECONDS_SET:
              if (theTime[0] < 0)
              {
                theTime[0] = theTime[0] - 1;
              }
              break;
            // otherwise don't do anything
            default:
              break;
          }
        }
      }
      
      // load the new time and date into the display buffer
      updateBuffer();
  
      // if blinkOff is true, blank the appropriate digits
      // in the display buffer before updating the display
      switch (setPos)
      {
        case HOURS_SET:
          displayBuffer[0] = ' ';
	  displayBuffer[1] = ' ';
          break;
        case MINUTES_SET:
          displayBuffer[2] = ' ';
	  displayBuffer[3] = ' ';
          break;
        case SECONDS_SET:
          displayBuffer[4] = ' ';
	  displayBuffer[5] = ' ';
          break;
        // otherwise don't do anything
        default:
          break;
      }
      
      // update the display
      updateDisplay(0, 7);

    } // end of the timing loop
    
    // if breakout is true, exit the main loop
    if (breakout)
    {
      break;
    }
    
    // 
    if (blinkOff)
    {
      blinkOff = 1;
    }
    else
    {
      blinkOff = 0;
    }    
    // end of the main loop
  }
  
  // set the time to the rtc
  setTimeRtc();
  return;  
}

//---------------------------------------------------------------------------------------------//
// function setDate
// sets the date
//---------------------------------------------------------------------------------------------//
void setDate(void)
{
  // default to the first setting position
  byte setPos = 0;
  // default to blink off
  byte blinkOff = 1;
  // signal to break out of an outer loop from an inner loop
  byte breakout = 0;
  
  getTimeRtc();
  getDateRtc();
    
  // convert time to dst if enabled
  if (dstEnable)
  {
    myLord.DST(theTime);
  }
    
  // compute the day of week
  day = myLord.DayOfWeek(theTime);

  // load the new time and date into the display buffer
  updateBuffer();
  // update the display
  // use 10-17 as that is where updateBuffer stores the date
  updateDisplay(10, 17);
 
  // array offsets
  // 0 second
  // 1 minute
  // 2 hour
  // 3 date
  // 4 month
  // 5 year

  while (1)
  {
    // grab now
    previousMillis = millis()
    // loop until SCROLL_DELAY has elapsed
    // toggle blinkOff and if true, blank the current setPos
    // this will blink the value to be set
    while (millis() - previousMillis < SCROLL_DELAY)
    {
      // the set button moves to the next value to be set
      // from left to right
      if (setButton.update())
      {
        if (setButton.read() == LOW)
        {
          // if we are already at the seconds position
          // set the time and exit
          if (setPos == 2)
  	  {
  	    setTimeRtc();
  	    // set the return flag
            breakout = 1;
            // exit the timing loop
            break;
  	  }
  	  // otherwise go to the next position
  	  else
  	  {
  	    setPos++;
  	  }
        }
      }
  
      // if the up button is pressed,
      // increment the value
      if (incButton.update())
      {
        if (incButton.read() == LOW)
        {
          // test each value and keep in range
          switch (setPos)
          {
            case MONTHS_SET:
              if (theTime[4] < 12)
              {
                theTime[4] = theTime[4] + 1;
              }
              break;
            case DAYS_SET:
              if (theTime[3] < 31)
              {
                theTime[3] = theTime[3] + 1;
              }
              break;
            case YEARS_SET:
              if (theTime[5] < 99)
              {
                theTime[5] = theTime[5] + 1;
              }
              break;
            case DOW_SET:
              if (day < 7)
              {
                day++;
              }
              break;
            // otherwise don't do anything
            default:
              break;
          }
        }    
      }
  
      // if the down button is pressed,
      // decrement the value
      if (decButton.update())
      {
        if (decButton.read() == LOW)
        {
          // test each value and keep in range
          switch (setPos)
          {
            case MONTHS_SET:
              if (theTime[4] > 0)
              {
                theTime[4] = theTime[4] - 1;
              }
              break;
            case DAYS_SET:
              if (theTime[3] < 0)
              {
                theTime[3] = theTime[3] - 1;
              }
              break;
            case YEARS_SET:
              if (theTime[5] < 0)
              {
                theTime[5] = theTime[5] - 1;
              }
              break;
            case DOW_SET:
              if (day > 0)
              {
                day--;
              }
              break;
            // otherwise don't do anything
            default:
              break;
          }
        }
      }
      
      // load the new time and date into the display buffer
      updateBuffer();
  
      // if blinkOff is true, blank the appropriate digits
      // in the display buffer before updating the display
      switch (setPos)
      {
        case MONTHS_SET:
          displayBuffer[10] = ' ';
	  displayBuffer[11] = ' ';
          break;
        case DAYS_SET:
          displayBuffer[12] = ' ';
	  displayBuffer[13] = ' ';
          break;
        case YEARS_SET:
          displayBuffer[14] = ' ';
	  displayBuffer[15] = ' ';
          break;
        case DOW_SET:
          displayBuffer[17] = ' ';
          break;
        // otherwise don't do anything
        default:
          break;
      }
      
      // update the display
      updateDisplay(10, 17);

    } // end of the timing loop
    
    // if breakout is true, exit the main loop
    if (breakout)
    {
      break;
    }
    
    // 
    if (blinkOff)
    {
      blinkOff = 1;
    }
    else
    {
      blinkOff = 0;
    }    
    // end of the main loop
  }
  
  // set the date to the rtc
  setDateRtc();
  return;  
}

//---------------------------------------------------------------------------------------------//
// function setDstStartEnd
// sets the DST start and end dates
//---------------------------------------------------------------------------------------------//
void setDstStartEnd(void)
{
  // default to the first setting position
  byte setPos = 0;
  // default to blink off
  byte blinkOff = 1;
  // signal to break out of an outer loop from an inner loop
  byte breakout = 0;
  
  // we do not use the updateBuffer routine
  // start month tens
  displayBuffer[0] = dstMonStart / 10;
  // start month ones - add a decimal point
  displayBuffer[1] = (dstMonStart % 10) + 128;
  // start week - add a decimal point
  displayBuffer[2] = dstWeekStart + 128;
  // end month tens
  displayBuffer[3] = dstMonEnd / 10;
  // end month ones - add a decimal point
  displayBuffer[4] = (dstMonEnd % 10) + 128;
  // end week - add a decimal point
  displayBuffer[5] = dstWeekEnd + 128;
  // a space
  displayBuffer[6] = ' ';
  // 1 - enabled, 0 - disabled
  displayBuffer[7] = dstEnable;
  
  // update the display
  // use 0 - 7
  updateDisplay(0, 7);

  while (1)
  {
    // grab now
    previousMillis = millis()
    // loop until SCROLL_DELAY has elapsed
    // toggle blinkOff and if true, blank the current setPos
    // this will blink the value to be set
    while (millis() - previousMillis < SCROLL_DELAY)
    {
      // the set button moves to the next value to be set
      // from left to right
      if (setButton.update())
      {
        if (setButton.read() == LOW)
        {
          // if we are already at the seconds position
          // set the time and exit
          if (setPos == DST_ENABLE)
  	  {
  	    // set the return flag
            breakout = 1;
            // exit the timing loop
            break;
  	  }
  	  // otherwise go to the next position
  	  else
  	  {
  	    setPos++;
  	  }
        }
      }
  
      // if the up button is pressed,
      // increment the value
      if (incButton.update())
      {
        if (incButton.read() == LOW)
        {
          // test each value and keep in range
          switch (setPos)
          {
            case DST_START_MON:
              if (dstMonStart < 12)
              {
                dstMonStart++;
              }
              break;
            case DST_START_WEEK:
              if (dstWeekStart < 4)
              {
                dstWeekStart++;
              }
              break;
            case DST_END_MON:
              if (dstMonEnd < 12)
              {
                dstMonEnd++;
              }
              break;
            case DST_END_WEEK:
              if (dstWeekEnd < 4)
              {
                dstWeekEnd++;
              }
              break;
            case DST_ENABLE:
              if (dstEnable < 1)
              {
                dstEnable++;
              }
              break;
            // otherwise don't do anything
            default:
              break;
          }
        }    
      }
  
      // if the down button is pressed,
      // decrement the value
      if (decButton.update())
      {
        if (decButton.read() == LOW)
        {
          // test each value and keep in range
          switch (setPos)
          {
            case DST_START_MON:
              if (dstMonStart > 1)
              {
                dstMonStart--;
              }
              break;
            case DST_START_WEEK:
              if (dstWeekStart > 1)
              {
                dstWeekStart--;
              }
              break;
            case DST_END_MON:
              if (dstMonEnd > 1)
              {
                dstMonEnd--;
              }
              break;
            case DST_END_WEEK:
              if (dstWeekEnd > 1)
              {
                dstWeekEnd--;
              }
              break;
            case DST_ENABLE:
              if (dstEnable > 0)
              {
                dstEnable--;
              }
              break;
            // otherwise don't do anything
            default:
              break;
          }
        }
      }
      
      // load the new time and date into the display buffer
      updateBuffer();
  
      // if blinkOff is true, blank the appropriate digits
      // in the display buffer before updating the display
      switch (setPos)
      {
        case DST_START_MON:
          displayBuffer[0] = ' ';
	  displayBuffer[1] = ' ' + 128;
          break;
        case DST_START_WEEK:
          displayBuffer[2] = ' ' + 128;
          break;
        case DST_END_MON:
          displayBuffer[3] = ' ';
	  displayBuffer[4] = ' ' + 128;
          break;
        case DST_END_WEEK:
          displayBuffer[5] = ' ';
          break;
        case DST_ENABLE:
          displayBuffer[7] = ' ';
          break;
        // otherwise don't do anything
        default:
          break;
      }
      
      // update the display
      updateDisplay(0, 7);

    } // end of the timing loop
    
    // if breakout is true, exit the main loop
    if (breakout)
    {
      break;
    }
    
    // 
    if (blinkOff)
    {
      blinkOff = 1;
    }
    else
    {
      blinkOff = 0;
    }    
    // end of the main loop
  }
  
  // write the dst dates to the eeprom
  // write the dst change info to the eeprom
  EEPROM.write(EE_DST_MON_START, dstMonStart);
  EEPROM.write(EE_DST_WEEK_START, dstWeekStart);
  EEPROM.write(EE_DST_MON_END, dstMonEnd);
  EEPROM.write(EE_DST_WEEK_END, dstWeekEnd);
  // write the dst enable flag to eeprom
  EEPROM.write(EE_DST_ENABLE, dstEnable);
  // update the dst calculation with the new values
  myLord.TimeZone(timezone * 60);
  myLord.DstRules(dstMonStart, dstWeekStart, dstMonEnd, dstWeekEnd, 60);
  return;  
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
// function setDateRtc
// sets the date on the DS3231 RTC
// uses the globals day date month year
//---------------------------------------------------------------------------------------------//
void setDateRtc()
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
// function getDateRtc
// gets the date from the DS3231 RTC
// uses the globals day date month year
//---------------------------------------------------------------------------------------------//
void getDateRtc()
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
// function setTimeRtc
// sets the time on the DS3231 RTC
// uses the global theTime[]
//---------------------------------------------------------------------------------------------//
void setTimeRtc()
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
// function getTimeRtc
// gets the time from the DS3231 RTC
// uses the global theTime[]
//---------------------------------------------------------------------------------------------//
void getTimeRtc()
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
  // timezone and dst info
  EEPROM.write(EE_TIME_ZONE, -5);
  EEPROM.write(EE_DST_MON_START, 3);
  EEPROM.write(EE_DST_WEEK_START, 1);
  EEPROM.write(EE_DST_MON_END, 10);
  EEPROM.write(EE_DST_WEEK_END, 1);
  EEPROM.write(EE_DST_ENABLE, 0);
  
  // set 24-hour mode
  EEPROM.write(EE_TIME_MODE, 0);

  // set alarm
  EEPROM.write(EE_AL_HR, 6);
  EEPROM.write(EE_AL_MIN, 0);
  // alarm is off
  EEPROM.write(EE_AL_MODE, 0);
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
  displayBuffer[17] = day;
}

//---------------------------------------------------------------------------------------------//
// function updateDisplay()
// updates the display based on the left and right displayBuffer positions
//---------------------------------------------------------------------------------------------//
void updateDisplay(byte bL, byte bR)
{
  byte r;
  byte n = 7;
  char c;
  byte dp = 0;

  for (r = bl; r < (br + 1); r++)
  {
    c = displayBuffer[r];
    if (c > 127)
    {
      c = c - 128;
      dp = 1;
    }
    else
    {
      dp = 0;
    }
    lc.setChar(0, n, r, dp);
    n--;
  }
}
