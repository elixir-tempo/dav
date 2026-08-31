        """
        accessUID = self.calendar().viewerHome().uid()
        oldCal = (yield self.component()) if not inserting else None

        # Duplicate before we do the merge because someone else may "own" the calendar object
        # and we should not change it. This is not ideal as we may duplicate it unnecessarily
        # but we currently have no api to let the caller tell us whether it cares about the
        # whether the calendar data is changed or not.
        try:
            component = PerUserDataFilter(accessUID).merge(component.duplicate(), oldCal)
        except ValueError:
            log.error("Invalid per-user data merge")
            raise InvalidPerUserDataMerge("Cannot merge per-user data")

        returnValue(component)

    def processScheduleTags(self, component, inserting, internal_state):

        # Check for scheduling object resource and write property
        if self.isScheduleObject:
            # Need to figure out when to change the schedule tag:
            #
            # 1. If this is not an internal request then the resource is being explicitly changed
            # 2. If it is an internal request for the Organizer, schedule tag never changes
            # 3. If it is an internal request for an Attendee and the message being processed came
            #    from the Organizer then the schedule tag changes.

            # Check what kind of processing is going on
            change_scheduletag = not (
                (internal_state == ComponentUpdateState.ORGANIZER_ITIP_UPDATE) or
                (internal_state == ComponentUpdateState.ATTENDEE_ITIP_UPDATE) and hasattr(self._txn, "doing_attendee_refresh")
            )

            if change_scheduletag or not self.scheduleTag:
                self.scheduleTag = str(uuid.uuid4())

            # Handle weak etag compatibility
            if config.Scheduling.CalDAV.ScheduleTagCompatibility:
                if change_scheduletag:
                    # Schedule-Tag change => weak ETag behavior must not happen
                    etags = ()
                else:
                    # Schedule-Tag did not change => add current ETag to list of those that can
                    # be used in a weak precondition test
                    etags = self.scheduleEtags
                    if etags is None:
                        etags = ()
                etags += (self._generateEtag(str(component)),)
                self.scheduleEtags = etags
            else:
                self.scheduleEtags = ()
        else:
            self.scheduleTag = ""
            self.scheduleEtags = ()

